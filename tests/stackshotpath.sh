#!/usr/bin/env bash
# Where sala looks for stackshot's programs (lib/stackshot-path.sh, and the small function in each Python module that needs one).
# stackshot moved its programs from the root of its checkout into a package (stackshot/fleet/client.py,
# stackshot/web/publish.py, stackshot/tools/open_item_text.py) and keeps a forwarder at each old root path for two weeks; sala's
# defaults take the package path when that file exists and the old root path when it is the only one, so a box with an older checkout
# keeps working, and a setting that names the file itself wins over the probe. Checked on fake checkouts in a temp folder, each in four
# layouts: new only, old only, both, none:
#   the shell helper (every name, an empty dir, an unknown name, no fork-free surprises with a trailing slash; `pages` is no name any more:
#   sala reads stackshot's project record and runs no pages.py) · stackshot_client (common.sh) with SALA_STACKSHOT_DIR on each layout,
#   SALA_STACKSHOT_CLIENT winning · the default commands of side.sh (its own lines, run as written) · the register command spawn prints · release.sh's
#   client · the Python modules (lib/unitjob.py, lib/pr_watcher_cleanup.py, contrib/question-board.py): the client path on each layout,
#   the explicit setting winning, an empty dir meaning none. The web app's roles command is in web/tests/test_roles_cmd.py.
# Isolated HOME in a temp folder (locked while the suite runs, removed at the end), no tmux, no process started but bash and python3.
# Usage: bash tests/stackshotpath.sh   (exit 0 = pass; a few seconds)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
T=""
trap '[ -n "$T" ] && rm -rf "$T"' EXIT
T=$(mktemp -d "${TMPDIR:-/tmp}/sala-sspath.XXXXXX")
exec 8< "$T"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock
export HOME="$T/home"; mkdir -p "$HOME/.claude" "$HOME/.config/salamander"
unset SALA_STACKSHOT_DIR SALA_STACKSHOT_CLIENT STACKSHOT_CLIENT SALA_SIDE_ITEMS_CMD SALA_SIDE_PAGE_TS_CMD SALA_SIDE_MSG_CMD

# mk <layout> <dir>: a fake checkout, its files empty (only their presence is read)
#   new = the package paths · old = the root paths · both = both (the forwarders beside the package) · none = an empty folder
mk() {
    local l=$1 d=$2 f
    mkdir -p "$d"
    case "$l" in new|both) for f in stackshot/fleet/client.py stackshot/web/publish.py stackshot/tools/open_item_text.py; do mkdir -p "$d/${f%/*}"; : > "$d/$f"; done ;; esac
    case "$l" in old|both) mkdir -p "$d/tools"; for f in client.py publish.py tools/open_item_text.py; do : > "$d/$f"; done ;; esac
}
LAYOUTS="new old both none"
for l in $LAYOUTS; do mk "$l" "$T/ss-$l"; done

# sx <script>: a fresh bash with lib/common.sh sourced under an empty config, SALA_STACKSHOT_DIR as the caller set it
sx() { SALA_CONFIG=/dev/null SALA_ROOT="$ROOT" bash -c '. "$SALA_ROOT/lib/common.sh"; '"$1" 2>&1; }

echo "== the shell helper: package path when it exists, else the old root path, else the package path"
want_of() {  # <layout> <name> → the relative path the helper must answer
    case "$1:$2" in
        new:*|both:*|none:*) case "$2" in client) echo stackshot/fleet/client.py ;; publish) echo stackshot/web/publish.py ;; open_item_text) echo stackshot/tools/open_item_text.py ;; esac ;;
        old:client) echo client.py ;; old:publish) echo publish.py ;; old:open_item_text) echo tools/open_item_text.py ;;
    esac
}
for l in $LAYOUTS; do
    all=1
    for n in client publish open_item_text; do
        got=$(SALA_CONFIG=/dev/null SALA_ROOT="$ROOT" bash -c '. "$SALA_ROOT/lib/common.sh"; stackshot_prog "$1" "$2"' _ "$T/ss-$l" "$n" 2>&1)
        [ "$got" = "$T/ss-$l/$(want_of "$l" "$n")" ] || { all=0; bad "layout $l, $n: '$got'"; }
    done
    [ "$all" = 1 ] && ok "layout $l: client, publish and open_item_text each at the expected path"
done
got=$(sx 'stackshot_prog "" client; echo "rc=$?"'); [ "$got" = "rc=1" ] && ok "an empty dir: nothing printed, status 1 (no stackshot on this box)" || bad "empty dir: '$got'"
got=$(sx 'stackshot_prog "'"$T/ss-new"'" nothing; echo "rc=$?"'); [ "$got" = "rc=2" ] && ok "an unknown name: nothing printed, status 2" || bad "unknown name: '$got'"
got=$(sx 'stackshot_prog "'"$T/ss-new"'" pages; echo "rc=$?"'); [ "$got" = "rc=2" ] && ok "pages is no name any more (sala runs no pages.py): nothing printed, status 2" || bad "pages name: '$got'"
got=$(sx 'stackshot_prog "'"$T/ss-new"'/" client'); [ "$got" = "$T/ss-new/stackshot/fleet/client.py" ] && ok "a trailing slash on the dir is not doubled" || bad "trailing slash: '$got'"
got=$(sx 'stackshot_prog_r v "'"$T/ss-old"'" publish; echo "$v"; stackshot_rel_r r "'"$T/ss-old"'" publish; echo "$r"'); [ "$got" = "$T/ss-old/publish.py
publish.py" ] && ok "the no-fork forms answer the same (the full path and the relative one)" || bad "_r forms: '$got'"

echo "== stackshot_client: the directory's probe, and a named file wins"
for l in $LAYOUTS; do
    c=$(sx 'SALA_STACKSHOT_DIR="'"$T/ss-$l"'"; stackshot_client; echo "rc=$?"')
    case "$l" in
        none) [ "$c" = "rc=1" ] && ok "layout none: no client (rc 1), as a box without the files" || bad "none: client '$c'" ;;
        old)  [ "$c" = "$T/ss-old/client.py
rc=0" ] && ok "layout old: the root client.py" || bad "old: client '$c'" ;;
        *)    [ "$c" = "$T/ss-$l/stackshot/fleet/client.py
rc=0" ] && ok "layout $l: the package client (the package wins when both are there)" || bad "$l: client '$c'" ;;
    esac
done
: > "$T/named-client.py"
c=$(sx 'SALA_STACKSHOT_DIR="'"$T/ss-new"'" SALA_STACKSHOT_CLIENT="'"$T/named-client.py"'"; stackshot_client')
[ "$c" = "$T/named-client.py" ] && ok "SALA_STACKSHOT_CLIENT wins over a directory that has the file" || bad "named: client '$c'"
c=$(sx 'SALA_STACKSHOT_DIR="'"$T/ss-new"'"; type agent_check_script >/dev/null 2>&1 && echo still-there || echo gone')
[ "$c" = "gone" ] && ok "agent_check_script is gone (no caller asks for a pages script)" || bad "agent_check_script: '$c'"
c=$(sx 'SALA_STACKSHOT_DIR="'"$T/ss-new"'" SALA_STACKSHOT_CLIENT="'"$T/no-such-client.py"'"; stackshot_client; echo "rc=$?"')
[ "$c" = "rc=1" ] && ok "a named client that is not there is not replaced by the directory's (rc 1)" || bad "named missing: '$c'"
c=$(sx 'SALA_STACKSHOT_DIR=""; stackshot_client; echo "rc=$?"'); [ "$c" = "rc=1" ] && ok "SALA_STACKSHOT_DIR empty: no client even though ~/stackshot could exist" || bad "empty dir: '$c'"
mk old "$HOME/stackshot"
c=$(sx 'stackshot_client'); [ "$c" = "$HOME/stackshot/client.py" ] && ok "SALA_STACKSHOT_DIR unset: ~/stackshot, probed the same way (an old checkout there)" || bad "unset dir: '$c'"
rm -rf "$HOME/stackshot"

echo "== the default commands of side.sh (its own lines, run as written; spawn.sh has none any more: the keeper message is gone)"
side_defaults() {  # <dir> → the three SALA_SIDE_*_CMD defaults, one per line
    SALA_CONFIG=/dev/null SALA_ROOT="$ROOT" SSDIR="$1" bash -c '. "$SALA_ROOT/lib/common.sh"; SALA_STACKSHOT_DIR=$SSDIR
        eval "$(sed -n "/^stackshot_prog_r _SIDE_CLIENT/,/^: \"\${SALA_SIDE_MSG_CMD=/p" "$SALA_ROOT/lib/side.sh")"
        printf "%s\n%s\n%s\n" "$SALA_SIDE_ITEMS_CMD" "$SALA_SIDE_PAGE_TS_CMD" "$SALA_SIDE_MSG_CMD"' 2>&1
}
for l in new old both; do
    rel=stackshot/fleet/client.py; [ "$l" = old ] && rel=client.py
    exp="python3 $T/ss-$l/$rel get items
python3 $T/ss-$l/$rel get page-ts
python3 $T/ss-$l/$rel message"
    got=$(side_defaults "$T/ss-$l")
    [ "$got" = "$exp" ] && ok "side.sh, layout $l: items, page-ts and message all go to $rel" || bad "side.sh $l: '$got'"
    ! grep -q '^stackshot_prog_r _SPAWN_CLIENT\|SALA_SPAWN_ASK_CMD' "$ROOT/lib/spawn.sh" && ok "spawn.sh, layout $l: no client default of its own (nobody is messaged)" || bad "spawn.sh still names a keeper ask"
done
got=$(side_defaults ""); [ -z "$got" ] && ok "side.sh, SALA_STACKSHOT_DIR empty: the three defaults are empty" || bad "side.sh empty: '$got'"
got=$(SALA_CONFIG=/dev/null SALA_ROOT="$ROOT" SSDIR="$T/ss-old" bash -c '. "$SALA_ROOT/lib/common.sh"; SALA_STACKSHOT_DIR=$SSDIR; SALA_SIDE_ITEMS_CMD="my own cmd"
        eval "$(sed -n "/^stackshot_prog_r _SIDE_CLIENT/,/^: \"\${SALA_SIDE_MSG_CMD=/p" "$SALA_ROOT/lib/side.sh")"; echo "$SALA_SIDE_ITEMS_CMD"' 2>&1)
[ "$got" = "my own cmd" ] && ok "a SALA_SIDE_ITEMS_CMD that is set stays as it is" || bad "named side cmd: '$got'"

echo "== the register command spawn prints names the client as this box has it"
reg() {  # <dir> → the command register_cmd prints for one agent
    SALA_CONFIG=/dev/null SALA_ROOT="$ROOT" SSDIR="$1" bash -c '. "$SALA_ROOT/lib/common.sh"; SALA_STACKSHOT_DIR=$SSDIR
        eval "$(sed -n "/^shell_dq() {/,/^}/p; /^register_cmd() {/,/^}/p" "$SALA_ROOT/lib/spawn.sh")"
        register_cmd projects/foo back example-foo-worker "" example-foo-main' 2>&1
}
got=$(reg "$T/ss-new"); [ "$got" = 'python3 ~/stackshot/stackshot/fleet/client.py post project-agent projects/foo example-foo-worker --role worker --back --mandate "<one line>"' ] && ok "layout new: ~/stackshot/stackshot/fleet/client.py" || bad "register new: '$got'"
got=$(reg "$T/ss-old"); [ "$got" = 'python3 ~/stackshot/client.py post project-agent projects/foo example-foo-worker --role worker --back --mandate "<one line>"' ] && ok "layout old: ~/stackshot/client.py" || bad "register old: '$got'"
got=$(reg "$T/ss-none"); [ "$got" = 'python3 ~/stackshot/stackshot/fleet/client.py post project-agent projects/foo example-foo-worker --role worker --back --mandate "<one line>"' ] && ok "no checkout: the package path (what the box will have)" || bad "register none: '$got'"

echo "== release.sh: its client follows the same probe, STACKSHOT_CLIENT wins"
# release.sh's own lines, run as written against each layout (the script itself is not started: it merges and deploys)
rel_client() {  # <dir> [STACKSHOT_CLIENT] → the CLIENT release.sh settles on
    HERE="$ROOT" SALA_STACKSHOT_DIR="$1" STACKSHOT_CLIENT="${2:-}" bash -c 'set -uo pipefail
        eval "$(sed -n "/^SS_DIR=/,/^CLIENT=/p" "$HERE/release.sh")"; echo "$CLIENT"' 2>&1
}
for l in new old both; do
    rel=stackshot/fleet/client.py; [ "$l" = old ] && rel=client.py
    got=$(rel_client "$T/ss-$l"); [ "$got" = "$T/ss-$l/$rel" ] && ok "release.sh, layout $l: $rel" || bad "release.sh $l: '$got'"
done
got=$(rel_client "$T/ss-new" "$T/named"); [ "$got" = "$T/named" ] && ok "release.sh: STACKSHOT_CLIENT wins" || bad "release.sh named: '$got'"
got=$(rel_client ""); [ -z "$got" ] && ok "release.sh: SALA_STACKSHOT_DIR empty is no client" || bad "release.sh empty: '$got'"

echo "== the Python modules: unitjob.py, pr_watcher_cleanup.py and question-board.py"
cat > "$T/pycheck.py" <<'PY'
import os, sys, types
sys.dont_write_bytecode = True   # no __pycache__ in the repo's folders
root, tree = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(root, "lib"))
def load(name, rel):   # the module's source run as written (read, not imported: no bytecode file stands in for it)
    p = os.path.join(root, rel); m = types.ModuleType(name); m.__file__ = p
    exec(compile(open(p, encoding="utf-8").read(), p, "exec"), m.__dict__); return m
mods = {"unitjob": (load("unitjob", "lib/unitjob.py"), "client_path"),
        "pr_watcher_cleanup": (load("pr_watcher_cleanup", "lib/pr_watcher_cleanup.py"), "stackshot_client"),
        "question-board": (load("question_board", "contrib/question-board.py"), "client_path")}
for k in ("SALA_STACKSHOT_CLIENT", "SALA_STACKSHOT_DIR"):
    os.environ.pop(k, None)
mode = sys.argv[3]
if mode == "dir":
    os.environ["SALA_STACKSHOT_DIR"] = tree
elif mode == "named":
    os.environ["SALA_STACKSHOT_DIR"] = tree; os.environ["SALA_STACKSHOT_CLIENT"] = os.path.join(tree, "named.py")
elif mode == "empty":
    os.environ["SALA_STACKSHOT_DIR"] = ""
for k, (m, fn) in mods.items():
    print(k, getattr(m, fn)())
PY
pyrun() { python3 -I "$T/pycheck.py" "$ROOT" "$@" 2>&1; }
for l in new old both; do
    rel=stackshot/fleet/client.py; [ "$l" = old ] && rel=client.py
    exp="unitjob $T/ss-$l/$rel
pr_watcher_cleanup $T/ss-$l/$rel
question-board $T/ss-$l/$rel"
    got=$(pyrun "$T/ss-$l" dir); [ "$got" = "$exp" ] && ok "layout $l: all three modules answer $rel" || bad "python $l: '$got'"
done
got=$(pyrun "$T/ss-none" dir); [ "$got" = "unitjob $T/ss-none/stackshot/fleet/client.py
pr_watcher_cleanup $T/ss-none/stackshot/fleet/client.py
question-board $T/ss-none/stackshot/fleet/client.py" ] && ok "layout none: the package path (the one a missing-client message names)" || bad "python none: '$got'"
got=$(pyrun "$T/ss-new" named); [ "$got" = "unitjob $T/ss-new/named.py
pr_watcher_cleanup $T/ss-new/named.py
question-board $T/ss-new/named.py" ] && ok "SALA_STACKSHOT_CLIENT wins in all three" || bad "python named: '$got'"
got=$(pyrun "$T/ss-new" empty | tr -d ' '); [ "$got" = "unitjob
pr_watcher_cleanup
question-board" ] && ok "SALA_STACKSHOT_DIR empty: no client in any of them" || bad "python empty: '$got'"
mk old "$HOME/stackshot"
got=$(HOME="$HOME" pyrun "$T/ss-new" unset); [ "$got" = "unitjob $HOME/stackshot/client.py
pr_watcher_cleanup $HOME/stackshot/client.py
question-board $HOME/stackshot/client.py" ] && ok "SALA_STACKSHOT_DIR unset: ~/stackshot, probed the same way" || bad "python unset: '$got'"
rm -rf "$HOME/stackshot"

[ "$fail" = 0 ] && echo "stackshotpath: pass" || echo "stackshotpath: FAIL"
exit "$fail"
