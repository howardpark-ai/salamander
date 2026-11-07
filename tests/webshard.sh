#!/usr/bin/env bash
# .github/scripts/web-shard.sh, which deals the web app's test files to the shards of tests.yml's `web-shard` job.
# A wrong split costs a test that never runs (a file in no shard) or runs twice, and neither shows as a failure, so this
# checks the split itself: on a throwaway tree with test files of known sizes, the union of shards 1..4 is exactly all
# tests/test_*.py of web/, the shards are disjoint, each is balanced (the largest files go to different shards) and the same
# on a second call, a new file is picked up by its name, a bad shard number or count exits 2 (nothing printed), and a shard
# with no file (more shards than files, or no test file at all) exits 1. Then the same on this checkout's real web/tests/.
# No network, no tmux, no process but the script itself.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
SCRIPT="$ROOT/.github/scripts/web-shard.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/sala-webshard.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
exec 8< "$T"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock

# a tree shaped like the repository: <tree>/.github/scripts/web-shard.sh and <tree>/web/tests/test_*.py
mk() {  # <tree> → the script in place, web/tests empty but for files that are no test (conftest.py, a fixture)
    mkdir -p "$1/.github/scripts" "$1/web/tests/fixtures"
    cp "$SCRIPT" "$1/.github/scripts/web-shard.sh"
    : > "$1/web/tests/conftest.py"; : > "$1/web/tests/fixtures/test_not_a_test.py"; : > "$1/web/tests/helper.py"
}
size() {  # <tree> <name> <bytes>
    head -c "$3" /dev/zero > "$1/web/tests/$2"
}
shard() { bash "$1/.github/scripts/web-shard.sh" "$2" "$3" 2>"$T/err"; }   # <tree> <shard> <n> → its files; stderr in $T/err

echo "== a tree of ten test files with distinct sizes"
A="$T/a"; mk "$A"
i=0; for n in a b c d e f g h i j; do i=$((i + 1)); size "$A" "test_$n.py" $((i * 100)); done
# by size, largest first: j i h g f e d c b a; dealt round-robin to four: 1 gets j f b, 2 gets i e a, 3 gets h d, 4 gets g c
want1="tests/test_j.py tests/test_f.py tests/test_b.py"; want2="tests/test_i.py tests/test_e.py tests/test_a.py"
want3="tests/test_h.py tests/test_d.py"; want4="tests/test_g.py tests/test_c.py"
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

echo "== equal sizes: ties by name, the same split everywhere"
B="$T/b"; mk "$B"
for n in e d c b a; do size "$B" "test_$n.py" 50; done
got=$(shard "$B" 1 2 | paste -sd' '); [ "$got" = "tests/test_a.py tests/test_c.py tests/test_e.py" ] && ok "ties are dealt by name (shard 1 of 2: a c e)" || bad "ties: '$got'"
got=$(LC_ALL=en_US.UTF-8 shard "$B" 2 2 | paste -sd' '); [ "$got" = "tests/test_b.py tests/test_d.py" ] && ok "… whatever the caller's locale (shard 2 of 2: b d)" || bad "locale: '$got'"

echo "== a new test file is picked up by its name"
size "$A" test_new.py 5000
got=$(shard "$A" 1 4 | head -1); [ "$got" = "tests/test_new.py" ] && ok "a new, largest file lands first in shard 1 with no list to edit" || bad "new file: '$got'"
rm -f "$A/web/tests/test_new.py"

echo "== a bad argument exits 2 and prints nothing on stdout"
for args in "" "1" "0 4" "5 4" "x 4" "1 x" "-1 4" "1 0" "1.5 4" "1 4 4" "01x 4" "1 4x"; do
    out=$(bash "$A/.github/scripts/web-shard.sh" $args 2>"$T/err"); rc=$?
    [ "$rc" = 2 ] && [ -z "$out" ] && grep -q '^usage: web-shard.sh' "$T/err" && ok "args '$args': usage, exit 2" || bad "args '$args': rc=$rc out='$out' err=$(cat "$T/err")"
done

echo "== a shard with no file exits 1"
out=$(shard "$A" 11 12); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && grep -q 'shard 11 of 12 has no test file' "$T/err" && ok "shard 11 of 12 over ten files: exit 1, named" || bad "11 of 12: rc=$rc out='$out' err=$(cat "$T/err")"
out=$(shard "$A" 12 12); rc=$?; [ "$rc" = 1 ] && ok "shard 12 of 12: exit 1" || bad "12 of 12: rc=$rc out='$out'"
out=$(shard "$A" 10 12); rc=$?; [ "$rc" = 0 ] && [ "$out" = "tests/test_a.py" ] && ok "shard 10 of 12 (the last file): exit 0" || bad "10 of 12: rc=$rc out='$out'"
E="$T/e"; mk "$E"
out=$(shard "$E" 1 4); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && grep -q 'no tests/test_\*.py under web/' "$T/err" && ok "no test file at all: exit 1, named" || bad "no tests: rc=$rc out='$out' err=$(cat "$T/err")"

echo "== this checkout's web/tests"
every=$(cd "$ROOT/web" && ls tests/test_*.py | sort); n=$(echo "$every" | wc -l)
if [ "$n" -ge 4 ]; then
    all=$(for s in 1 2 3 4; do bash "$SCRIPT" $s 4; done | sort)
    [ "$all" = "$every" ] && ok "the four shards deal exactly the $n tests/test_*.py of web/" || bad "real union differs: $(diff <(echo "$all") <(echo "$every") | head -5)"
    [ -z "$(echo "$all" | uniq -d)" ] && ok "… each in one shard only" || bad "a real file is in two shards"
    c1=$(bash "$SCRIPT" 1 4 | wc -l); c4=$(bash "$SCRIPT" 4 4 | wc -l)
    [ $((c1 - c4)) -le 1 ] && [ $((c4 - c1)) -le 1 ] && ok "… the shards differ by at most one file ($c1 and $c4)" || bad "unbalanced: shard 1 has $c1 files, shard 4 has $c4"
else
    ok "no web/tests here ($n test files): the real-tree check does not apply"
fi

[ "$fail" = 0 ] && echo "webshard: pass" || echo "webshard: FAIL"
exit $fail
