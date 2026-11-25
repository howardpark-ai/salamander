#!/usr/bin/env bash
# tests/machines.sh — the fleet's machines as plain data (lib/machines.py `machine_list`) and the two CLI verbs on it, `sala machines [--json]` and
# `sala host ROLE [--field F | --set HOST]` (lib/machines.sh; docs/subcommands.md). Made-up machine files in a temporary folder; no real machine, tmux server, sala-web or network.
#  - machine_list on a normal fleet: one entry per machine with its name, hostname, letter, ssh alias, addresses, host roles, retired flag and source files, in the
#    names file's order (a retired letter after the others), then the machines only the other files name; names meet without regard to case, and an OS hostname meets its fleet name
#  - a machine in one file and not in another is still listed with the missing parts empty: a machine in the candidates, ssh, holds and follow files but not the names file, one
#    only in the follow list, one only in the ssh file; a missing file, an unreadable file and a malformed holds file are no error and no entry
#  - `sala machines --json` is machine_list's answer (and its text form lists the same names), a file named and not read is said, no file named is exit 2, --help and a bad call
#  - `sala host sala --field hostname` is the holds script's own answer on the same files (a stand-in script of its contract here; the owner's real script too where it is on this machine),
#    and so is every field and the line with no field; `--set` of a host the candidates do not list is refused with the script's text and exit code and changes nothing; of a listed one
#    changes only the record, and the machine list then shows the role on the new host
#  - both verbs run with no tmux server, no sala-web and no running sala, and write nothing into the machine files
# Cleanup: the temporary folder (prefix sc1565-) is held with flock while the suite runs and removed on exit, pass or fail; no process is started that outlives a command and none is killed.
# Usage: bash tests/machines.sh   (exit 0 = pass; a few seconds)
set -u
unset TMUX TMUX_PANE XDG_STATE_HOME SALA_MASTER SALA_FLEET_NAMES SALA_MACHINE_FOLLOW_MACHINES MACHINE_HOLDS_TOML MACHINE_HOLDS_CANDIDATES MACHINE_HOLDS_HUB TNR_CONF
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
T=""
cleanup() { [ -z "$T" ] || { exec 8<&-; rm -rf "$T" 2>/dev/null; }; true; }; trap cleanup EXIT   # set before the folder exists
T=$(mktemp -d "${TMPDIR:-/tmp}/sc1565-XXXXXX")
exec 8< "$T"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock
case "$T" in /tmp/*|"${TMPDIR:-/tmp}"/*) ;; *) echo "machines: the temporary folder is not under the temporary directory ($T) - refusing to run"; exit 1 ;; esac
export HOME=$T/home SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC XDG_RUNTIME_DIR=$T/run TMUX_TMPDIR=$T/tmux SALA_AUTO_UPDATE=off PYTHONDONTWRITEBYTECODE=1
mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$TMUX_TMPDIR"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT"
SALA="$ROOT/bin/salamander"
D=$T/data   # the owner's data folder: the fleet names file and, beside it, the others
mkdir -p "$D/claude/tailnet-route" "$D/ssh" "$D/claude/host-move" "$D/claude/machine-follow"

printf '%s\t%s\t%s\n' '# os hostname' 'fleet name' 'board letter' > "$D/fleet-names.tsv"
printf '%s\t%s\t%s\n' alpha-os example-alpha a beta-os example-beta b GAMMA-OS example-gamma c >> "$D/fleet-names.tsv"
echo '# d = example-delta, retired (gone for good): the letter stays reserved' >> "$D/fleet-names.tsv"
cat > "$D/claude/tailnet-route/candidates.conf" <<'EOF'
# the tailnet's hosts
name sala.example.invalid
host example-alpha 192.0.2.1 2001:db8::1
host example-eps 192.0.2.5 2001:db8::5   # in no names file row
host Gamma-OS 192.0.2.3 2001:db8::3      # named by its OS hostname, in other letters
via example-eps example-alpha ssh
EOF
cat > "$D/ssh/fleet.conf" <<'EOF'
# fleet ssh config
Host example-alpha
  HostName alpha.example.invalid
Host example-beta example-eta
  HostName beta.example.invalid
Host *
  User nobody
EOF
cat > "$D/claude/host-move/machine-holds.toml" <<'EOF'
[[hosts]]
role = "sala-host"
host = "example-alpha"
name = "sala.example.invalid"

[[hosts]]
role = "stackshot-host"
host = "example-eps"
name = "stackshot.example.invalid"
EOF
cat > "$D/claude/machine-follow/machines.toml" <<'EOF'
run_on = "example-alpha"

[machines.example-eps]
follows = ["cli"]
command = ["true"]

[machines.example-zeta]
follows = ["cli"]
command = ["true"]
EOF
# a stand-in of the owner's holds script, to the contract the verbs run it by: `host ROLE [--field F]` and `set-host ROLE HOST` over the two files its environment names
cat > "$D/claude/host-move/machine_holds.py" <<'PY'
#!/usr/bin/env python3
import os, re, sys, tomllib
def fail(m, c=2):
    print("machine_holds: " + m, file=sys.stderr); sys.exit(c)
toml_p, cand_p = os.environ["MACHINE_HOLDS_TOML"], os.environ["MACHINE_HOLDS_CANDIDATES"]
hosts = {}
for ln in open(cand_p):
    w = ln.split("#", 1)[0].split()
    if len(w) == 4 and w[0] == "host":
        hosts[w[1]] = (w[2], w[3])
role = None
if len(sys.argv) > 2:
    role = sys.argv[2] if sys.argv[2].endswith("-host") else sys.argv[2] + "-host"
    if role not in ("sala-host", "stackshot-host"):
        fail("unknown host role '%s' (one of sala, stackshot)" % sys.argv[2])
if sys.argv[1] == "host":
    rec = next(h for h in tomllib.load(open(toml_p, "rb"))["hosts"] if h["role"] == role)
    if rec["host"] not in hosts:
        fail("%s records %s on '%s', which candidates.conf does not list" % (os.path.basename(toml_p), role, rec["host"]))
    v = {"hostname": rec["host"], "ipv4": hosts[rec["host"]][0], "ipv6": hosts[rec["host"]][1], "ssh": rec["host"]}
    f = sys.argv[sys.argv.index("--field") + 1] if "--field" in sys.argv else None
    if f is not None and f not in v:
        fail("argument --field: invalid choice: '%s' (choose from hostname, ipv4, ipv6, ssh)" % f)
    print(v[f] if f else "|".join(v[k] for k in ("hostname", "ipv4", "ipv6", "ssh")))
elif sys.argv[1] == "set-host":
    new = sys.argv[3]
    if new not in hosts:
        fail("'%s' is not a `host` of candidates.conf (it lists %s): nothing was written" % (new, ", ".join(hosts)))
    text = open(toml_p).read()
    m = re.search(r'(role = "%s"\nhost = )"([^"]*)"' % role, text)
    open(toml_p, "w").write(text[:m.start(2) - 1] + '"%s"' % new + text[m.end(2) + 1:])
    print("%s: %s -> %s" % (role, m.group(2), new))
else:
    fail("unknown command", 1)
PY
chmod +x "$D/claude/host-move/machine_holds.py"
export SALA_FLEET_NAMES=$D/fleet-names.tsv SALA_MACHINE_FOLLOW_MACHINES=$D/claude/machine-follow/machines.toml
FILES=("$D/fleet-names.tsv" "$D/claude/tailnet-route/candidates.conf" "$D/ssh/fleet.conf" "$D/claude/host-move/machine-holds.toml" "$D/claude/machine-follow/machines.toml")
sum() { sha256sum "${FILES[@]}" | awk '{print $1}' | tr '\n' ' '; }
ML() {   # ML <python expr over `m`, the list machine_list() returns for the paths given in the environment> → its repr
    python3 -I -c 'import json, os, sys
sys.path.insert(0, sys.argv[1] + "/lib")
import machines
m = machines.machine_list(os.environ.get("FN") or None, os.environ.get("FO") or None)
print(json.dumps(eval(sys.argv[2]), sort_keys=True))' "$ROOT" "$1"
}
FN=$SALA_FLEET_NAMES FO=$SALA_MACHINE_FOLLOW_MACHINES; export FN FO

echo "== machine_list on a normal fleet"
got=$(ML '[x["name"] for x in m]')
[ "$got" = '["example-alpha", "example-beta", "example-gamma", "example-delta", "example-eps", "example-eta", "example-zeta"]' ] \
    && ok "seven machines: the names file's rows, the retired letter after them, then the ones only the other files name (candidates, ssh, follow)" || bad "names/order: $got"
got=$(ML '[[x["name"], x["letter"], x["hostname"], x["ssh"]] for x in m]')
[ "$got" = '[["example-alpha", "a", "alpha-os", "example-alpha"], ["example-beta", "b", "beta-os", "example-beta"], ["example-gamma", "c", "GAMMA-OS", ""], ["example-delta", "d", "", ""], ["example-eps", "", "example-eps", ""], ["example-eta", "", "", "example-eta"], ["example-zeta", "", "example-zeta", ""]]' ] \
    && ok "letter, OS hostname and ssh alias of each: the OS hostname is the names file's first column, else the candidates', else the follow list's" || bad "identity: $got"
got=$(ML '[[x["name"], x["addresses"], x["roles"], x["retired"]] for x in m if x["name"] in ("example-alpha", "example-gamma", "example-delta", "example-eps")]')
[ "$got" = '[["example-alpha", ["192.0.2.1", "2001:db8::1"], ["sala-host"], false], ["example-gamma", ["192.0.2.3", "2001:db8::3"], [], false], ["example-delta", [], [], true], ["example-eps", ["192.0.2.5", "2001:db8::5"], ["stackshot-host"], false]]' ] \
    && ok "addresses from the candidates (a host named by its OS hostname in other letters meets its fleet name), the host roles from the holds records, the retired flag from the names file's comment" || bad "addresses/roles/retired: $got"
got=$(ML '[[x["name"], x["sources"]] for x in m]')
[ "$got" = '[["example-alpha", ["fleet-names.tsv", "candidates.conf", "fleet.conf", "machine-holds.toml"]], ["example-beta", ["fleet-names.tsv", "fleet.conf"]], ["example-gamma", ["fleet-names.tsv", "candidates.conf"]], ["example-delta", ["fleet-names.tsv"]], ["example-eps", ["candidates.conf", "machine-holds.toml", "machines.toml"]], ["example-eta", ["fleet.conf"]], ["example-zeta", ["machines.toml"]]]' ] \
    && ok "each entry names the files it came from, in the files' own order" || bad "sources: $got"
got=$(ML 'all(list(x) == ["name", "hostname", "letter", "ssh", "addresses", "roles", "retired", "sources"] for x in m)')
[ "$got" = true ] && ok "every entry has the same keys in the same order, a missing part being empty (never absent)" || bad "keys: $got"
got=$(ML '[x["name"] for x in m if x["letter"] == "" and "fleet-names.tsv" not in x["sources"] and x["addresses"] and x["ssh"] == ""]')
[ "$got" = '["example-eps"]' ] && ok "a machine in the candidates, holds and follow files but not in the names file (a box with no board letter) is listed, with its addresses and no letter" || bad "a box with no letter: $got"

echo "== a missing, unreadable or malformed file is no error"
mkdir -p "$T/only"; cp "$D/fleet-names.tsv" "$T/only/fleet-names.tsv"
got=$(FN=$T/only/fleet-names.tsv FO= ML '[[x["name"], x["ssh"], x["addresses"], x["roles"], x["sources"]] for x in m][:2]')
[ "$got" = '[["example-alpha", "", [], [], ["fleet-names.tsv"]], ["example-beta", "", [], [], ["fleet-names.tsv"]]]' ] && ok "only the names file there: the machines are listed with the other parts empty" || bad "names file alone: $got"
got=$(FN=$T/none/fleet-names.tsv FO= ML 'm')
[ "$got" = '[]' ] && ok "no file there at all: an empty list, no error" || bad "nothing: $got"
got=$(FN= FO=$D/claude/machine-follow/machines.toml ML '[x["name"] for x in m]')
[ "$got" = '["example-eps", "example-zeta"]' ] && ok "only the follow list named: its machines" || bad "follow only: $got"
cp -r "$D" "$T/bad"; printf 'this is [not toml\n' > "$T/bad/claude/host-move/machine-holds.toml"; rm "$T/bad/ssh/fleet.conf"; mkdir "$T/bad/ssh/fleet.conf"   # a directory where the file should be: it cannot be read
got=$(FN=$T/bad/fleet-names.tsv FO= ML '[[x["name"], x["roles"], x["ssh"]] for x in m][:2]')
[ "$got" = '[["example-alpha", [], ""], ["example-beta", [], ""]]' ] && ok "a holds file that is not TOML and an ssh file that cannot be read (a folder stands where it should be) count as empty (the machines stay listed, without roles and ssh aliases)" || bad "malformed: $got"
printf '%s\t%s\t%s\n' alpha-os Example-Alpha a >> "$T/bad/fleet-names.tsv"
got=$(FN=$T/bad/fleet-names.tsv FO= ML '[x["name"] for x in m if x["name"].lower() == "example-alpha"]')
[ "$got" = '["example-alpha"]' ] && ok "a name written in another case is the same machine" || bad "case: $got"

echo "== sala machines"
before=$(sum)
out=$(bash "$SALA" machines 2>&1); rc=$?
[ "$rc" = 0 ] && ok "sala machines: exit 0" || bad "sala machines exit $rc: $out"
n=$(printf '%s\n' "$out" | grep -c '^example-')
[ "$n" = 7 ] && ok "one line for each of the seven machines" || bad "lines: $n in: $out"
case "$out" in *"example-delta"*retired*) ok "the retired machine says so" ;; *) bad "retired not shown: $out" ;; esac
case "$out" in *"sala-host"*"stackshot-host"*) ok "the host roles are shown" ;; *) bad "roles not shown: $out" ;; esac
case "$out" in *"not read"*) bad "a file reported unread on a full fleet: $out" ;; *) ok "no 'not read' line when every file was read" ;; esac
js=$(bash "$SALA" machines --json 2>&1); rc=$?
[ "$rc" = 0 ] && ok "sala machines --json: exit 0" || bad "--json exit $rc"
want=$(ML 'm')
printf '%s' "$js" | python3 -c 'import json, sys; d = json.load(sys.stdin); sys.exit(0 if d["machines"] == json.loads(sys.argv[1]) and d["schema"] == 1 and d["not_read"] == [] else 1)' "$want" \
    && ok "--json holds exactly machine_list's machines, schema 1 and nothing unread" || bad "--json differs from machine_list"
SALA_MACHINE_FOLLOW_MACHINES=$T/nowhere.toml bash "$SALA" machines | grep -q 'not read: machines.toml' && ok "a follow file named and not there is said on the last line" || bad "no 'not read' line"
SALA_MACHINE_FOLLOW_MACHINES=$T/nowhere.toml bash "$SALA" machines --json | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["not_read"] == ["machines.toml"] and len(d["machines"]) == 6 else 1)' && ok "--json: not_read names it, and the other machines are still there" || bad "--json not_read"
out=$(SALA_FLEET_NAMES= SALA_MACHINE_FOLLOW_MACHINES= bash "$SALA" machines 2>&1); rc=$?
[ "$rc" = 2 ] && case "$out" in *"SALA_FLEET_NAMES"*) true ;; *) false ;; esac && ok "no file named: exit 2 and the setting to set" || bad "no files: rc=$rc $out"
out=$(bash "$SALA" machines --bogus 2>&1); rc=$?; [ "$rc" = 2 ] && ok "a bad option is exit 2" || bad "bad option: rc=$rc"
out=$(bash "$SALA" machines --help 2>&1); rc=$?; [ "$rc" = 0 ] && case "$out" in "usage: sala machines"*) true ;; *) false ;; esac && ok "--help: the usage, exit 0" || bad "--help rc=$rc"
[ "$(sum)" = "$before" ] && ok "the machine files are as they were (read-only)" || bad "a machine file changed"

echo "== sala host"
holds() { MACHINE_HOLDS_TOML=$D/claude/host-move/machine-holds.toml MACHINE_HOLDS_CANDIDATES=$D/claude/tailnet-route/candidates.conf python3 "$D/claude/host-move/machine_holds.py" "$@"; }
for role in sala stackshot; do
    for f in hostname ipv4 ipv6 ssh; do
        a=$(bash "$SALA" host $role --field $f 2>&1); b=$(holds host $role --field $f 2>&1)
        [ "$a" = "$b" ] && [ -n "$a" ] || bad "host $role --field $f: '$a' vs the script's '$b'"
    done
    a=$(bash "$SALA" host $role 2>&1); b=$(holds host $role 2>&1)
    [ "$a" = "$b" ] && [ -n "$a" ] && ok "host $role (every field and the whole line) is the holds script's own answer: $(printf '%s' "$a" | cut -d'|' -f1)" || bad "host $role: '$a' vs '$b'"
done
[ "$(bash "$SALA" host sala --field hostname)" = example-alpha ] && ok "sala host sala --field hostname says the machine the record names" || bad "hostname answer"
out=$(bash "$SALA" host nobody 2>&1); rc=$?; want=$(holds host nobody 2>&1); wrc=$?
[ "$rc" = "$wrc" ] && [ "$out" = "$want" ] && [ "$rc" = 2 ] && ok "an unknown role: the script's refusal text and exit code ($rc), unchanged" || bad "unknown role: rc=$rc/$wrc '$out' vs '$want'"
out=$(bash "$SALA" host sala --field name 2>&1); rc=$?; want=$(holds host sala --field name 2>&1); wrc=$?
[ "$rc" = "$wrc" ] && [ "$out" = "$want" ] && [ "$rc" = 2 ] && ok "a field the script does not have: its refusal and exit code, unchanged" || bad "bad field: rc=$rc/$wrc '$out' vs '$want'"
before=$(sum)
out=$(bash "$SALA" host sala --set example-unlisted 2>&1); rc=$?; want=$(holds set-host sala example-unlisted 2>&1); wrc=$?
[ "$rc" = "$wrc" ] && [ "$rc" = 2 ] && [ "$out" = "$want" ] && ok "--set of a host the candidates do not list: the script's text and exit code (2), unchanged" || bad "unlisted: rc=$rc/$wrc '$out' vs '$want'"
case "$out" in *"nothing was written"*) ok "…and the text says nothing was written" ;; *) bad "text: $out" ;; esac
[ "$(sum)" = "$before" ] && ok "…and no machine file changed" || bad "a refused --set changed a file"
out=$(bash "$SALA" host sala --set example-beta 2>&1); rc=$?
[ "$rc" = 2 ] && ok "--set of a machine that is in the names file but not in the candidates is refused too" || bad "beta: rc=$rc $out"
out=$(bash "$SALA" host sala --set example-eps 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$out" = "sala-host: example-alpha -> example-eps" ] && ok "--set of a listed host: the script's own line, exit 0" || bad "listed: rc=$rc '$out'"
[ "$(bash "$SALA" host sala --field hostname)" = example-eps ] && ok "the record now names it, as sala host reads it" || bad "record not moved"
bash "$SALA" machines --json | python3 -c 'import json,sys; d={m["name"]: m["roles"] for m in json.load(sys.stdin)["machines"]}; sys.exit(0 if d["example-eps"] == ["sala-host", "stackshot-host"] and d["example-alpha"] == [] else 1)' \
    && ok "sala machines shows the role on its new machine" || bad "the list did not follow the record"
bash "$SALA" host sala --set example-alpha >/dev/null 2>&1
[ "$(bash "$SALA" host sala --field hostname)" = example-alpha ] && ok "set back" || bad "set back failed"
for a in "" "sala --field" "sala --set" "sala --field hostname --set example-alpha" "sala extra"; do
    # shellcheck disable=SC2086
    out=$(bash "$SALA" host $a 2>&1); rc=$?
    [ "$rc" = 2 ] || bad "host [$a]: rc=$rc"
done
ok "a call with no role, a missing value, both --field and --set, or a stray argument: exit 2"
out=$(bash "$SALA" host --help 2>&1); rc=$?; [ "$rc" = 0 ] && case "$out" in "usage: sala host"*) true ;; *) false ;; esac && ok "--help: the usage, exit 0" || bad "host --help rc=$rc"
mv "$D/claude/host-move/machine_holds.py" "$D/claude/host-move/machine_holds.py.off"
out=$(bash "$SALA" host sala 2>&1); rc=$?
[ "$rc" = 2 ] && case "$out" in *"holds script is not there"*) true ;; *) false ;; esac && ok "no holds script: one line saying where it is looked for, exit 2" || bad "no script: rc=$rc $out"
mv "$D/claude/host-move/machine_holds.py.off" "$D/claude/host-move/machine_holds.py"

echo "== no running sala"
if command -v tmux >/dev/null 2>&1; then
    case "$(command tmux ls 2>&1)" in *"no server"*|*"No such file"*|*"error connecting"*) ok "(this run has no tmux server of its own: TMUX_TMPDIR is empty)" ;; *) bad "a tmux server answered under the suite's TMUX_TMPDIR" ;; esac
fi
[ ! -e "$XDG_RUNTIME_DIR/sala-web" ] && ok "no sala-web socket exists here" || bad "a sala-web socket exists"
SALA_WEB_SOCKET=$T/none.sock bash "$SALA" machines >/dev/null 2>&1 && bash "$SALA" host sala --field hostname >/dev/null 2>&1 && ok "both verbs answer with sala-web stopped and no sala session" || bad "a verb needed a running sala"

echo "== the owner's real holds script, where it is on this machine"
REAL_SCRIPT=${SALA_PARITY_MACHINE_HOLDS:-}   # the owner's own script, copied into the fixture (never written to)
if [ -n "$REAL_SCRIPT" ] && [ -f "$REAL_SCRIPT" ]; then
    cp "$REAL_SCRIPT" "$D/claude/host-move/machine_holds.py"
    printf '%s\n' "[[hosts]]" 'role = "sala-host"' 'host = "example-alpha"' 'name = "sala.example.invalid"' '' "[[hosts]]" 'role = "stackshot-host"' 'host = "example-eps"' 'name = "stackshot.example.invalid"' > "$D/claude/host-move/machine-holds.toml"
    for f in hostname ipv4 ipv6 ssh; do
        a=$(bash "$SALA" host sala --field $f 2>&1); b=$(holds host sala --field $f 2>&1)
        [ "$a" = "$b" ] && [ -n "$a" ] || bad "real script: host sala --field $f: '$a' vs '$b'"
    done
    a=$(bash "$SALA" host stackshot 2>&1); b=$(holds host stackshot 2>&1)
    [ "$a" = "$b" ] && [ -n "$a" ] && ok "sala host answers as the real script does on the same files (every field of sala's record, the whole line of stackshot's)" || bad "real script, whole line: '$a' vs '$b'"
    before=$(sum)
    out=$(bash "$SALA" host sala --set example-unlisted 2>&1); rc=$?; want=$(holds set-host sala example-unlisted 2>&1); wrc=$?
    [ "$rc" = "$wrc" ] && [ "$rc" = 2 ] && [ "$out" = "$want" ] && [ "$(sum)" = "$before" ] && ok "--set of an unlisted host: the real script's refusal text and exit code (2), nothing written" || bad "real unlisted: rc=$rc/$wrc '$out' vs '$want'"
    out=$(bash "$SALA" host sala --set example-eps 2>&1); rc=$?
    [ "$rc" = 0 ] && [ "$out" = "sala-host: example-alpha -> example-eps" ] && [ "$(bash "$SALA" host sala --field hostname)" = example-eps ] && ok "--set of a listed host: the real script moves the record (its own line, exit 0)" || bad "real set: rc=$rc '$out'"
else
    echo "  skip real script: SALA_PARITY_MACHINE_HOLDS names none (set it to the owner's machine_holds.py); a machine without it skips this section"
fi

[ "$fail" = 0 ] && echo "machines: pass" || echo "machines: FAIL"
exit $fail
