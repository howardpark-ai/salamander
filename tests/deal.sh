#!/usr/bin/env bash
# .github/scripts/deal.py and what uses it, which deal CI's tests to its shards by their RECORDED times (greedy longest-first bin
# packing, the pytest-split `least_duration` way; tests/timings.json for the shell suites, web/tests/timings.json for the web test
# files). A wrong deal costs a test that never runs (in no shard) or runs twice, and neither shows as a failure, and a bad balance
# costs only wall time and shows nowhere, so this checks the deal itself:
#   the dealer on hand-worked timings (the exact shards, longest first inside each), a balance bound that holds for ANY timings
#   (Graham's: the worst shard is within the sum over N plus the heaviest item), every item in exactly one shard, the same deal on a second call and
#   whatever order the items arrive in, the fallbacks (an item with no recorded time weighs the median; a recorded item that is
#   gone is ignored; no timings file at all deals evenly), the exits (2 for a bad argument or a timings file that is not valid,
#   1 for a shard with no item unless --allow-empty);
#   tests/run.sh --shard K/N and --list on a throwaway tree of stub suites (the shares are disjoint and cover every suite, only the
#   share runs, a suite with no recorded time is dealt, an empty share exits 0 and says so, a bad --shard exits 2);
#   .github/scripts/update_timings.py on saved-log text (the suites' `════` lines, the web files' time from pytest's progress-line
#   timestamps, the median over runs, a key no run showed kept, a key whose file is gone dropped, a run that ran few suites not counted);
#   then this checkout's two timings files: valid, and the real deals cover every suite and every web test file once.
# No network, no tmux, no process but the scripts themselves.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
DEAL="$ROOT/.github/scripts/deal.py"
T=$(mktemp -d "${TMPDIR:-/tmp}/sala-deal.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
exec 8< "$T"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock

tj() {  # <file> then name=seconds…  → a timings file
    local f="$1"; shift
    python3 -I - "$f" "$@" <<'EOF'
import json, sys
t = {k: float(v) for k, v in (a.split("=", 1) for a in sys.argv[2:])}
json.dump({"version": 1, "unit": "seconds", "timings": t}, open(sys.argv[1], "w"))
EOF
}
dl() { python3 -I "$DEAL" "$@" 2>"$T/err"; }   # stderr in $T/err

echo "== hand-worked: six items of 10 9 8 7 6 5 s to two shards"
tj "$T/six.json" a=10 b=9 c=8 d=7 e=6 f=5
# longest first, each to the lightest shard (a tie to the lower number): a→1, b→2, c→2 (9 < 10), d→1 (10 < 17), e→1 (17 = 17, lower number), f→2
got1=$(dl --timings "$T/six.json" --of 2 --shard 1 f e d c b a | paste -sd' '); got2=$(dl --timings "$T/six.json" --of 2 --shard 2 f e d c b a | paste -sd' ')
[ "$got1" = "a d e" ] && ok "shard 1 of 2: a d e (23 s), longest first" || bad "shard 1: '$got1'"
[ "$got2" = "b c f" ] && ok "shard 2 of 2: b c f (22 s)" || bad "shard 2: '$got2'"
all=$(dl --timings "$T/six.json" --of 2 a b c d e f | paste -sd' ')
[ "$all" = "$(printf '1\ta 1\td 1\te 2\tb 2\tc 2\tf')" ] && ok "without --shard: every item with its shard" || bad "all: '$all'"
dl --timings "$T/six.json" --of 2 --report a b c d e f >/dev/null
grep -q 'shard 1 of 2: 3 items, about 23 s' "$T/err" && grep -q 'shard 2 of 2: 3 items, about 22 s' "$T/err" && grep -q '6 with a recorded time' "$T/err" && ok "--report: the shape of the deal on stderr" || bad "report: $(cat "$T/err")"
got=$(dl --timings "$T/six.json" --of 1 --shard 1 a b c d e f | paste -sd' '); [ "$got" = "a b c d e f" ] && ok "one shard of one: every item, longest first" || bad "1 of 1: '$got'"

echo "== size and name are not the weight: the recorded time is"
tj "$T/rev.json" tests/test_big.py=1 tests/test_mid.py=50 tests/test_small.py=100
got=$(dl --timings "$T/rev.json" --of 2 --shard 1 tests/test_big.py tests/test_mid.py tests/test_small.py | paste -sd' ')
[ "$got" = "tests/test_small.py" ] && ok "the slowest file is alone in shard 1 whatever its name sorts as" || bad "slowest: '$got'"

echo "== equal weights: ties by name (byte order), a tie between shards to the lower number"
tj "$T/eq.json" e=5 d=5 c=5 b=5 a=5
got=$(dl --timings "$T/eq.json" --of 2 --shard 1 e d c b a | paste -sd' '); [ "$got" = "a c e" ] && ok "shard 1 of 2: a c e" || bad "ties 1: '$got'"
got=$(LC_ALL=en_US.UTF-8 dl --timings "$T/eq.json" --of 2 --shard 2 e d c b a | paste -sd' '); [ "$got" = "b d" ] && ok "shard 2 of 2: b d, whatever the caller's locale" || bad "ties 2: '$got'"
tj "$T/case.json" B=5 a=5
got=$(dl --timings "$T/case.json" --of 2 --shard 1 a B | paste -sd' '); [ "$got" = "B" ] && ok "byte order: B before a" || bad "case: '$got'"

echo "== the same deal on a second call, and whatever order the items arrive in"
python3 -I - "$T/many.json" "$T/many.txt" <<'EOF'
import json, random, sys
r = random.Random(7)
names = [f"tests/test_{i:03d}.py" for i in range(150)]
t = {n: round(r.paretovariate(1.2) * 3, 1) for n in names[:140]}   # a heavy tail like a real run; ten items have no record
json.dump({"version": 1, "unit": "seconds", "timings": t}, open(sys.argv[1], "w"))
open(sys.argv[2], "w").write("\n".join(names) + "\n")
EOF
a=$(dl --timings "$T/many.json" --of 6 - < "$T/many.txt"); b=$(dl --timings "$T/many.json" --of 6 - < "$T/many.txt")
[ "$a" = "$b" ] && ok "a second call gives the same deal" || bad "the deal changed between two calls"
c=$(sort -r "$T/many.txt" | dl --timings "$T/many.json" --of 6 -); d=$(shuf --random-source=<(yes) "$T/many.txt" | dl --timings "$T/many.json" --of 6 -)
[ "$a" = "$c" ] && [ "$a" = "$d" ] && ok "reversed or shuffled input: the same deal" || bad "the deal depends on the input order"
e=$(dl --timings "$T/many.json" --of 6 $(cat "$T/many.txt")); [ "$a" = "$e" ] && ok "items as arguments or on stdin: the same deal" || bad "arguments differ from stdin"
dup=$(printf '%s\n%s\n' "$(cat "$T/many.txt")" "$(head -3 "$T/many.txt")" | dl --timings "$T/many.json" --of 6 -); [ "$a" = "$dup" ] && ok "an item named twice is dealt once" || bad "a repeated item changed the deal"

echo "== every item in exactly one shard (150 items, 6 shards)"
all=$(for s in 1 2 3 4 5 6; do dl --timings "$T/many.json" --of 6 --shard $s - < "$T/many.txt"; done | sort)
[ "$all" = "$(sort "$T/many.txt")" ] && ok "the union of the six shards is exactly the 150 items" || bad "union: $(diff <(echo "$all") <(sort "$T/many.txt") | head -4)"
[ -z "$(echo "$all" | uniq -d)" ] && ok "… and none is in two shards" || bad "an item is in two shards"

echo "== balance: the worst shard is within Graham's list-scheduling bound (sum / N + the heaviest item), on random timings"
for seed in 1 2 3 4 5 6; do
    python3 -I - "$T/rnd.json" "$T/rnd.txt" "$seed" <<'EOF'
import json, random, sys
r = random.Random(int(sys.argv[3]))
n = r.choice([12, 40, 124])
names = [f"x{i:03d}" for i in range(n)]
t = {k: round(r.lognormvariate(2, 1.3), 1) for k in names}
json.dump({"version": 1, "unit": "seconds", "timings": t}, open(sys.argv[1], "w"))
open(sys.argv[2], "w").write("\n".join(names) + "\n")
EOF
    bound=$(python3 -I - "$T/rnd.json" "$T/rnd.txt" "$DEAL" <<'EOF'
import json, subprocess, sys
t = json.load(open(sys.argv[1]))["timings"]; items = open(sys.argv[2]).read().split()
worst = 0.0
for n in (2, 4, 6):
    out = subprocess.run([sys.executable, "-I", sys.argv[3], "--timings", sys.argv[1], "--of", str(n), "-"], input="\n".join(items), capture_output=True, text=True).stdout
    load = [0.0] * n
    for line in out.splitlines():
        k, i = line.split("\t"); load[int(k) - 1] += t[i]
    # any greedy deal (each item to the lightest shard) ends within sum/N + (N-1)/N x the heaviest item; LPT is also within 4/3 of the optimum
    bound = sum(t.values()) / n + (n - 1) / n * max(t.values())
    worst = max(worst, max(load) / bound)
print(f"{worst:.3f}")
EOF
)
    python3 -I -c "import sys; sys.exit(0 if float('$bound') <= 1.0 else 1)" && ok "seed $seed: the worst shard is $bound of the bound (2, 4 and 6 shards)" || bad "seed $seed: the worst shard is $bound of the bound, above 1"
done

echo "== the fallbacks: a new test weighs the median, a gone one is ignored, no file deals evenly"
tj "$T/med.json" p=10 q=20 r=30 s=40 t=1000
# the median of the five is 30; the new item "n" weighs 30, so it comes after t (1000) and s (40), tied with r (30; n before r by name)
dl --timings "$T/med.json" --of 2 --report n p q r s t >/dev/null
grep -q 'shard 1 of 2: 1 items, about 1000 s' "$T/err" && grep -q 'shard 2 of 2: 5 items, about 130 s' "$T/err" && grep -q '5 with a recorded time, the rest at the median' "$T/err" \
    && ok "a new item weighs the median (30 s): shard 2 holds p q r s and it, 130 s" || bad "median: $(cat "$T/err")"
got=$(dl --timings "$T/med.json" --of 2 --shard 2 n p q r s t | paste -sd' '); [ "$got" = "s n r q p" ] && ok "… ahead of the lighter items and behind the heavier, longest first" || bad "median order: '$got'"
a=$(dl --timings "$T/med.json" --of 2 p q r s t); tj "$T/gone.json" p=10 q=20 r=30 s=40 t=1000 vanished=5000 alsogone=1
b=$(dl --timings "$T/gone.json" --of 2 p q r s t)
[ "$a" = "$b" ] && ok "a recorded item that is not among the items is ignored (the same deal)" || bad "a gone key changed the deal"
dl --timings "$T/gone.json" --of 2 --report p q r s t >/dev/null; grep -q '5 items to 2 shards' "$T/err" && ok "… and not counted" || bad "gone key counted: $(cat "$T/err")"
out=$(dl --timings "$T/none.json" --of 2 --shard 1 a b c d e | paste -sd' '); rc=$?
[ "$out" = "a c e" ] && grep -q 'no recorded times' "$T/err" && ok "no timings file: every item weighs the same, one note, a deal is still made" || bad "no file: rc=$rc out='$out' err=$(cat "$T/err")"
echo '{"version": 1, "timings": {}}' > "$T/empty.json"
out=$(dl --timings "$T/empty.json" --of 2 --shard 2 a b c d e | paste -sd' '); [ "$out" = "b d" ] && ok "a file with no timings: the same" || bad "empty: '$out'"
out=$(dl --of 2 --shard 1 a b c | paste -sd' '); [ "$out" = "a c" ] && ok "no --timings at all: the same" || bad "no option: '$out'"

echo "== exits"
for args in "" "--of 0 a" "--of x a" "--of 2 --shard 3 a" "--of 2 --shard 0 a" "--of 2 --shard x a" "--of" "--timings" "--bogus --of 2 a"; do
    out=$(python3 -I "$DEAL" $args 2>"$T/err"); rc=$?
    [ "$rc" = 2 ] && [ -z "$out" ] && ok "args '$args': exit 2, nothing on stdout" || bad "args '$args': rc=$rc out='$out'"
done
for body in 'not json' '[1,2]' '{"version":1}' '{"timings":[1]}' '{"timings":{"a":"fast"}}' '{"timings":{"a":-1}}' '{"timings":{"a":true}}' '{"timings":{"a":NaN}}'; do
    printf '%s' "$body" > "$T/bad.json"
    out=$(python3 -I "$DEAL" --timings "$T/bad.json" --of 2 --shard 1 a b 2>"$T/err"); rc=$?
    [ "$rc" = 2 ] && [ -z "$out" ] && grep -q 'bad.json' "$T/err" && ok "timings '$body': exit 2, names the file" || bad "timings '$body': rc=$rc out='$out' err=$(cat "$T/err")"
done
out=$(dl --timings "$T/six.json" --of 5 --shard 5 a b c); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && grep -q 'shard 5 of 5 has no item' "$T/err" && ok "a shard with no item: exit 1, named" || bad "empty shard: rc=$rc out='$out' err=$(cat "$T/err")"
out=$(dl --timings "$T/six.json" --of 5 --shard 5 --allow-empty a b c); rc=$?; [ "$rc" = 0 ] && [ -z "$out" ] && ok "… exit 0 with --allow-empty" || bad "allow-empty: rc=$rc out='$out'"
out=$(dl --timings "$T/six.json" --of 2 --shard 1 </dev/null); rc=$?; [ "$rc" = 1 ] && [ -z "$out" ] && ok "no items at all: exit 1" || bad "no items: rc=$rc"
out=$(dl --timings "$T/six.json" --of 2 --shard 1 - </dev/null); rc=$?; [ "$rc" = 1 ] && ok "… also from an empty stdin" || bad "empty stdin: rc=$rc"

echo "== tests/run.sh --shard K/N and --list on a throwaway tree of stub suites"
R="$T/tree"; mkdir -p "$R/tests" "$R/.github/scripts" "$R/ran"
cp "$ROOT/tests/run.sh" "$R/tests/run.sh"; cp "$DEAL" "$R/.github/scripts/deal.py"
for n in alpha bravo charlie delta echo foxtrot golf; do
    printf '#!/usr/bin/env bash\n: > "%s/ran/%s"; echo "  ok   %s"\n' "$R" "$n" "$n" > "$R/tests/$n.sh"
done
tj "$R/tests/timings.json" tests/alpha.sh=10 tests/bravo.sh=9 tests/charlie.sh=8 tests/delta.sh=7 tests/echo.sh=6 tests/foxtrot.sh=5 tests/gone.sh=900
# golf has no recorded time: it weighs the median of the seven recorded (5 6 7 8 9 10 900 → 8), tied with charlie (charlie first by name)
# the deal to two: alpha→1, bravo→2, charlie→2 (9 < 10), golf→1 (10 < 17), delta→2 (17 < 18), echo→1 (18 < 24), foxtrot→1 (24 = 24, lower number)
rs() { bash "$R/tests/run.sh" "$@" 2>"$T/err"; }
got=$(rs --list | tr -d '\n'); [ "$got" = "alpha bravo charlie golf delta echo foxtrot" ] && ok "--list with no shard: every suite, longest recorded first (golf at the median)" || bad "list: '$got'"
s1=$(rs --shard 1/2 --list); s2=$(rs --shard 2/2 --list)
[ "$s1 | $s2" = "alpha golf echo foxtrot | bravo charlie delta" ] && ok "--shard 1/2 and 2/2: alpha golf echo foxtrot | bravo charlie delta" || bad "shares: '$s1' | '$s2'"
[ "$(echo "$s1 $s2" | tr ' ' '\n' | sort | paste -sd' ')" = "alpha bravo charlie delta echo foxtrot golf" ] && ok "the two shares are disjoint and cover every suite" || bad "shares do not partition the suites"
got=$(rs --shard 2/2 --list golf alpha bravo | tr -d '\n'); [ "$got" = "bravo golf" ] && ok "--shard over named suites deals only those (shard 2: bravo golf)" || bad "named: '$got'"
rm -rf "$R/ran"; mkdir -p "$R/ran"
out=$(rs --shard 2/2); rc=$?
[ "$rc" = 0 ] && [ "$(ls "$R/ran" | paste -sd' ')" = "bravo charlie delta" ] && ok "a real run of --shard 2/2 runs exactly its share" || bad "run: rc=$rc ran=$(ls "$R/ran" | paste -sd' ')"
grep -q 'all passed' <<< "$out" && grep -q 'summary (3 in parallel' <<< "$out" && ok "… and its summary lists three suites" || bad "summary: $out"
out=$(rs --shard 2/2 alpha); rc=$?; [ "$rc" = 0 ] && grep -q 'nothing to do' <<< "$out" && ok "a share with no suite exits 0 and says so (named alpha is in shard 1)" || bad "empty share: rc=$rc out=$out"
out=$(rs --shard 2/2 --list alpha); [ "$out" = "" ] && ok "--list of an empty share prints an empty line and nothing else" || bad "list empty: '$out'"
for sh in 0/2 3/2 1 a/b 1/0 /2 1/2/3; do
    out=$(rs --shard "$sh"); rc=$?; [ "$rc" = 2 ] && grep -q 'takes K/N' "$T/err" && ok "--shard $sh: exit 2" || bad "--shard $sh: rc=$rc"
done
out=$(rs --shard 2>&1); rc=$?
[ "$rc" != 0 ] && ok "--shard with no value: refused" || bad "--shard alone: rc=$rc"
rm -f "$R/tests/timings.json"; got=$(rs --shard 1/2 --list | tr -d '\n')
[ "$got" = "alpha charlie echo golf" ] && grep -q 'no recorded times' "$T/err" && ok "no timings file: the suites are dealt evenly, by name" || bad "no timings: '$got' $(cat "$T/err")"
printf 'not json' > "$R/tests/timings.json"
out=$(rs --shard 1/2 --list); rc=$?; [ "$rc" = 2 ] && ok "--shard with a timings file that is not valid: exit 2" || bad "bad timings with --shard: rc=$rc"
got=$(rs --list | tr -d '\n'); rc=$?; [ "$rc" = 0 ] && [ "$got" = "alpha bravo charlie delta echo foxtrot golf" ] && ok "… without --shard a broken file only leaves the order as it was" || bad "bad timings, no shard: rc=$rc '$got'"
mv "$R/.github/scripts/deal.py" "$R/.github/scripts/deal.py.off"
out=$(rs --shard 1/2); rc=$?; [ "$rc" = 2 ] && ok "no dealer: --shard exits 2" || bad "no dealer with --shard: rc=$rc"
rm -rf "$R/ran"; mkdir -p "$R/ran"; out=$(rs alpha bravo); rc=$?
[ "$rc" = 0 ] && [ "$(ls "$R/ran" | paste -sd' ')" = "alpha bravo" ] && ok "… without --shard it runs as it always did" || bad "no dealer, no shard: rc=$rc"

echo "== update_timings.py on saved-log text"
U="$T/upd"; mkdir -p "$U/.github/scripts" "$U/tests" "$U/web/tests"
cp "$ROOT/.github/scripts/update_timings.py" "$ROOT/.github/scripts/deal.py" "$U/.github/scripts/"
for i in $(seq -w 1 22); do : > "$U/tests/s$i.sh"; done
: > "$U/web/tests/test_one.py"; : > "$U/web/tests/test_two.py"; : > "$U/web/tests/test_three.py"
python3 -I - "$T" "$U" <<'EOF'
import sys
T, U = sys.argv[1:3]
def suites(secs):  # a run's `suites` job: 22 suites, s01 takes secs, the rest 4 s
    lines = [f"suites\tUNKNOWN STEP\t2026-11-10T11:5{i % 10}:00.1234567Z ════ tests/s{i + 1:02d}.sh (pass, {secs if i == 0 else 4}s)" for i in range(22)]
    lines.append("suites\tUNKNOWN STEP\t2026-11-10T11:59:59.0000000Z ════ tests/s02.sh (FAIL, exit 1, 999s)")
    lines.append("suites\tUNKNOWN STEP\t2026-11-10T11:59:59.0000000Z ════ tests/gone.sh (pass, 50s)")
    return "\n".join(lines) + "\n"
def web(a, b):  # a shard: two files, the first took a s, the second b s (wrapped over two progress lines); "collected" starts the clock
    t0 = 1000
    def ts(s):
        h, r = divmod(int(t0 + s), 3600); m, sec = divmod(r, 60)
        return f"2026-11-09T17:{m:02d}:{sec:02d}.5000000Z"
    return "\n".join([
        f"web-shard (1)\tUNKNOWN STEP\t{ts(0)} collected 40 items",
        f"web-shard (1)\tUNKNOWN STEP\t{ts(0)} ",
        f"web-shard (1)\tUNKNOWN STEP\t{ts(a)} tests/test_one.py ...........s.....                     [ 30%]",
        f"web-shard (1)\tUNKNOWN STEP\t{ts(a + b / 2)} tests/test_two.py ..................................... [ 60%]",
        f"web-shard (1)\tUNKNOWN STEP\t{ts(a + b)} ......                                                    [ 70%]",
        f"web-shard (1)\tUNKNOWN STEP\t{ts(a + b + 3)} tests/test_gone.py ..F                                     [ 80%]",
        f"web-shard (1)\tUNKNOWN STEP\t{ts(a + b + 3)} FAILED something",
    ]) + "\n"
for n, (s, w) in enumerate([(10, (20, 100)), (30, (40, 200)), (20, (30, 150))]):
    open(f"{T}/log{n}.txt", "w").write(suites(s) + web(*w))
open(f"{T}/few.txt", "w").write("\n".join(f"suites\tx\t2026-11-10T11:50:0{i}.0000000Z ════ tests/s{i + 1:02d}.sh (pass, 900s)" for i in range(5)) + "\n")
import json
json.dump({"version": 1, "unit": "seconds", "timings": {"tests/s22.sh": 7.5, "tests/s21.sh": 1.0, "tests/long_gone.sh": 5}}, open(f"{U}/tests/timings.json", "w"))
EOF
# the old file keeps s22 (seen again, replaced by the median 4), loses long_gone (no file); s21 is seen: 4
( cd "$U" && python3 -I .github/scripts/update_timings.py --from-logs "$T/log0.txt" "$T/log1.txt" "$T/log2.txt" "$T/few.txt" --label "stub logs" ) > "$T/upd.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "update_timings.py --from-logs: exit 0" || bad "update: rc=$rc $(cat "$T/upd.out")"
q() { python3 -I -c "import json,sys; d=json.load(open('$1')); print(d['timings'].get('$2','absent'), d['source'])"; }
read -r v _ <<< "$(q "$U/tests/timings.json" tests/s01.sh)"; [ "$v" = "20.0" ] && ok "a suite's time is the median over the runs (10, 30, 20 → 20)" || bad "s01: $v"
read -r v _ <<< "$(q "$U/tests/timings.json" tests/s02.sh)"; [ "$v" = "4.0" ] && ok "a FAIL line is not a time (s02 stays at its passing 4)" || bad "s02: $v"
read -r v _ <<< "$(q "$U/tests/timings.json" tests/gone.sh)"; [ "$v" = "absent" ] && ok "a suite whose file is gone is not recorded" || bad "gone: $v"
read -r v _ <<< "$(q "$U/tests/timings.json" tests/long_gone.sh)"; [ "$v" = "absent" ] && ok "… and an old key whose file is gone is dropped" || bad "long_gone: $v"
read -r v _ <<< "$(q "$U/tests/timings.json" tests/s22.sh)"; [ "$v" = "4.0" ] && ok "a seen suite replaces the old number" || bad "s22: $v"
grep -q '3 of 4 logs showed suites' "$T/upd.out" && ok "a log with five suites is not counted (3 of 4 logs)" || bad "few: $(cat "$T/upd.out")"
read -r v rest <<< "$(q "$U/tests/timings.json" tests/s01.sh)"; [ "$rest" = "median over 3 CI logs (stub logs), by .github/scripts/update_timings.py" ] && ok "the file says where its numbers came from" || bad "source: $rest"
read -r v _ <<< "$(q "$U/web/tests/timings.json" tests/test_one.py)"; [ "$v" = "30.0" ] && ok "web: a file's time is the gap to the previous progress line (20, 40, 30 s → 30)" || bad "test_one: $v"
read -r v _ <<< "$(q "$U/web/tests/timings.json" tests/test_two.py)"; [ "$v" = "150.0" ] && ok "web: a file wrapped over two progress lines gets both gaps (100, 200, 150 s → 150)" || bad "test_two: $v"
read -r v _ <<< "$(q "$U/web/tests/timings.json" tests/test_gone.py)"; [ "$v" = "absent" ] && ok "web: a file that is not in the checkout is not recorded" || bad "test_gone: $v"
read -r v _ <<< "$(q "$U/web/tests/timings.json" tests/test_three.py)"; [ "$v" = "absent" ] && ok "web: a file no log showed gets no number (the dealer gives it the median)" || bad "test_three: $v"
before=$(cat "$U/tests/timings.json"); ( cd "$U" && python3 -I .github/scripts/update_timings.py --dry-run --from-logs "$T/log0.txt" ) >/dev/null 2>&1
[ "$(cat "$U/tests/timings.json")" = "$before" ] && ok "--dry-run writes nothing" || bad "--dry-run wrote the file"
( cd "$U" && python3 -I .github/scripts/update_timings.py --from-logs /nonexistent ) >/dev/null 2>&1; [ "$?" = 2 ] && ok "a log that cannot be read: exit 2" || bad "missing log: rc=$?"
( cd "$U" && python3 -I .github/scripts/update_timings.py --bogus ) >/dev/null 2>&1; [ "$?" = 2 ] && ok "an unknown option: exit 2" || bad "bogus option: rc=$?"

echo "== this checkout's timings files"
for f in tests/timings.json web/tests/timings.json; do
    [ -f "$ROOT/$f" ] || { ok "no $f here: its checks do not apply"; continue; }
    python3 -I - "$ROOT/.github/scripts" "$ROOT/$f" <<'EOF' && ok "$f is valid: every time a number of seconds >= 0" || bad "$f is not valid"
import sys
sys.path.insert(0, sys.argv[1]); import deal
t = deal.load_timings(sys.argv[2]); assert t, "no timings"
EOF
done
suites=$(cd "$ROOT" && for f in tests/*.sh; do n=$(basename "$f" .sh); case "$n" in lib|run|count-procs|suitemap) ;; *) echo "$f" ;; esac; done)
web=$(cd "$ROOT/web" 2>/dev/null && ls tests/test_*.py 2>/dev/null)
check_real() {  # <family> <timings file> <items> <shard counts…>
    local fam="$1" tf="$2" items="$3"; shift 3
    local n all
    for n in "$@"; do
        all=$(for s in $(seq 1 "$n"); do echo "$items" | dl --timings "$tf" --of "$n" --shard "$s" --allow-empty -; done | sort)
        [ "$all" = "$(echo "$items" | sort)" ] && [ -z "$(echo "$all" | uniq -d)" ] && ok "$fam: $n shards deal every one of the $(echo "$items" | wc -l) once" || bad "$fam, $n shards: $(diff <(echo "$all") <(echo "$items" | sort) | head -4)"
    done
}
[ -f "$ROOT/tests/timings.json" ] && check_real "suites" "$ROOT/tests/timings.json" "$suites" 1 2 3
[ -n "$web" ] && [ -f "$ROOT/web/tests/timings.json" ] && check_real "web" "$ROOT/web/tests/timings.json" "$web" 4 6
if [ -n "$web" ] && [ -f "$ROOT/web/tests/timings.json" ]; then
    # shard 1 of the real web deal holds a file of the records, and no shard of six is empty
    for s in 1 2 3 4 5 6; do [ -n "$(echo "$web" | dl --timings "$ROOT/web/tests/timings.json" --of 6 --shard $s -)" ] || bad "web shard $s of 6 is empty"; done; ok "no web shard of six is empty"
fi

[ "$fail" = 0 ] && echo "deal: pass" || echo "deal: FAIL"
exit $fail
