#!/usr/bin/env bash
# The client-side hooks (.githooks/) also run the machine's global hook of the same name (.githooks/chain-global; CONTRIBUTING.md,
# "Clean commit and PR text"). In a throwaway repo whose core.hooksPath is a copy of .githooks, with HOME and XDG_CONFIG_HOME in a
# temporary folder that holds fake global hooks: no global hook = the repo's own check alone decides; a failing global hook fails
# commit-msg, pre-commit, pre-merge-commit and pre-push; it gets the same arguments and, for pre-push, the same stdin lines; a global
# hook that is not executable is ignored; a failing repo check fails even when the global hook passes; the user's global
# core.hooksPath is honoured over the XDG default; a global setting that points back at the repo's own hooks does not loop.
# Nothing on the network; the addresses are made-up. The temporary folder is made first under a trap, locked for the run, and
# removed on the way out, pass or fail.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
T=""
trap '[ -n "$T" ] && rm -rf "$T"' EXIT
T=$(mktemp -d "${TMPDIR:-/tmp}/sala-githooks-chain.XXXXXX")
exec 8< "$T"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock
export HOME="$T/home" XDG_CONFIG_HOME="$T/xdg" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$XDG_CONFIG_HOME"
unset GIT_CONFIG_GLOBAL GIT_DIR GIT_WORK_TREE CLEAN_TEXT_BRANCH CLEAN_TEXT_TITLE CLEAN_TEXT_BODY CLEAN_TEXT_BASE CLEAN_TEXT_HEAD
export CLEAN_TEXT_DENY="quill"   # made up; the hooks read the deny data from the environment

# A copy of the hooks in the layout they expect (<tree>/.githooks, <tree>/.github/scripts/clean_text.py).
TREE="$T/tree"; mkdir -p "$TREE/.github/scripts"
cp -R "$ROOT/.githooks" "$TREE/.githooks"; cp "$ROOT/.github/scripts/clean_text.py" "$TREE/.github/scripts/"
for f in chain-global commit-msg pre-commit pre-merge-commit pre-push; do
    [ -x "$ROOT/.githooks/$f" ] && ok ".githooks/$f is executable" || bad ".githooks/$f is not executable"
done

# Fake global hooks. Each logs its name and arguments to $GLOG, keeps its stdin in $T/gin-<name>, and exits 1 when its name is in
# $GFAIL (a space-separated list in the environment git hands on to the hooks).
GH="$XDG_CONFIG_HOME/git/hooks"; GLOG="$T/glog"; export GLOG
mkdir -p "$GH"
for n in commit-msg pre-commit pre-merge-commit pre-push; do
    cat > "$GH/$n" <<'EOF'
#!/bin/sh
n=$(basename "$0")
printf '%s|%s\n' "$n" "$*" >> "$GLOG"
cat > "$(dirname "$GLOG")/gin-$n"
case " ${GFAIL:-} " in *" $n "*) echo "global $n: refused" >&2; exit 1 ;; esac
exit 0
EOF
    chmod +x "$GH/$n"
done
fresh() { : > "$GLOG"; rm -f "$T"/gin-*; }
ran() { grep -c "^$1|" "$GLOG"; }   # how many times the global hook $1 ran

R="$T/repo"; REM="$T/remote.git"
git init -q -b main "$R"; git -C "$R" config user.email t@example.invalid; git -C "$R" config user.name t
git -C "$R" config commit.gpgsign false; git -C "$R" config core.hooksPath "$TREE/.githooks"
git init -q --bare -b main "$REM"; git -C "$R" remote add origin "$REM"
unset GFAIL
cm() { out=$(git -C "$R" commit -q --allow-empty "$@" 2>&1); rc=$?; }
push() { out=$(git -C "$R" push "$@" 2>&1); rc=$?; }
n() { git -C "$R" rev-list --count HEAD 2>/dev/null || echo 0; }
# The board ids the repo check must refuse are made up here from two pieces, so that this file holds no such token itself (the
# clean-text check would otherwise count each one it spells out).
pfx=board; ID1="$pfx#9003"; ID2="$pfx#9004"; ID3="$pfx#9005"

echo "== (a) no global hook: the repo's own check alone decides"
mv "$GH" "$GH.off"
cm -m "start the project"
[ "$rc" = 0 ] && [ "$(n)" = 1 ] && ok "a clean message commits with no global hook" || bad "clean commit: rc=$rc $out"
cm -m "fix the thing for $ID1"
[ "$rc" != 0 ] && grep -qxF "message: $ID1 (board id)" <<< "$out" && [ "$(n)" = 1 ] && ok "the repo check still refuses a bad message with no global hook" || bad "bad commit: rc=$rc $out"
push origin main
[ "$rc" = 0 ] && [ "$(git -C "$REM" rev-parse main)" = "$(git -C "$R" rev-parse main)" ] && ok "pre-push with no global hook: a clean push goes through" || bad "push: rc=$rc $out"
mv "$GH.off" "$GH"

echo "== (b) a failing global hook fails each of the four hooks"
export GFAIL="commit-msg"; fresh; c=$(n)
cm -m "second commit"
[ "$rc" != 0 ] && grep -qF "global commit-msg: refused" <<< "$out" && [ "$(n)" = "$c" ] && ok "commit-msg: a failing global hook refuses the commit" || bad "commit-msg: rc=$rc $out"
export GFAIL="pre-commit"; fresh
cm -m "second commit"
[ "$rc" != 0 ] && grep -qF "global pre-commit: refused" <<< "$out" && [ "$(n)" = "$c" ] && ok "pre-commit: a failing global hook refuses the commit" || bad "pre-commit: rc=$rc $out"
unset GFAIL; cm -m "side base"; git -C "$R" checkout -q -b side; cm -m "side work"; git -C "$R" checkout -q main; cm -m "main work"
export GFAIL="pre-merge-commit"; fresh; c=$(n)
out=$(git -C "$R" merge --no-ff -m "merge side" side 2>&1); rc=$?
[ "$rc" != 0 ] && grep -qF "global pre-merge-commit: refused" <<< "$out" && [ "$(n)" = "$c" ] && ok "pre-merge-commit: a failing global hook refuses the merge commit" || bad "pre-merge-commit: rc=$rc $out"
git -C "$R" merge --abort 2>/dev/null
export GFAIL="pre-push"; fresh
push origin main
[ "$rc" != 0 ] && grep -qF "global pre-push: refused" <<< "$out" && [ "$(git -C "$REM" rev-parse main)" != "$(git -C "$R" rev-parse main)" ] && ok "pre-push: a failing global hook refuses the push, and the remote keeps its old main" || bad "pre-push: rc=$rc $out"
unset GFAIL

echo "== (c) the global hook gets the same arguments and stdin"
fresh
cm -m "third commit"
[ "$rc" = 0 ] && [ "$(ran commit-msg)" = 1 ] && [ "$(ran pre-commit)" = 1 ] && ok "a passing global hook lets the commit through, each hook ran once" || bad "pass-through: rc=$rc $out"
args=$(sed -n 's/^commit-msg|//p' "$GLOG")
[ "$args" = "$R/.git/COMMIT_EDITMSG" ] || [ "$args" = ".git/COMMIT_EDITMSG" ] && ok "commit-msg: the global hook got the message file as its one argument" || bad "commit-msg args: [$args]"
git -C "$R" branch -q other
fresh
rem_main=$(git -C "$REM" rev-parse main)   # main is on the remote already, `other` is new there
push origin main other
sh_main=$(git -C "$R" rev-parse main); zero=0000000000000000000000000000000000000000
args=$(sed -n 's/^pre-push|//p' "$GLOG")
[ "$rc" = 0 ] && [ "$args" = "origin $REM" ] && ok "pre-push: the global hook got the remote's name and url" || bad "pre-push args: rc=$rc [$args] $out"
in="$T/gin-pre-push"
[ "$(wc -l < "$in")" = 2 ] && grep -qxF "refs/heads/main $sh_main refs/heads/main $rem_main" "$in" && grep -qxF "refs/heads/other $sh_main refs/heads/other $zero" "$in" && ok "pre-push: the global hook read the same stdin, one line per ref" || bad "pre-push stdin: $(cat "$in")"

echo "== (d) a global hook that is not executable is ignored"
chmod -x "$GH/commit-msg" "$GH/pre-push"; export GFAIL="commit-msg pre-push"; fresh
cm -m "fourth commit"; r1=$rc
push origin main; r2=$rc
[ "$r1" = 0 ] && [ "$r2" = 0 ] && [ "$(ran commit-msg)" = 0 ] && [ "$(ran pre-push)" = 0 ] && ok "a non-executable global commit-msg and pre-push hook is not run, and does not fail" || bad "non-executable: r1=$r1 r2=$r2 $out"
chmod +x "$GH/commit-msg" "$GH/pre-push"; unset GFAIL

echo "== (e) the repo check failing still fails when the global hook passes"
fresh; c=$(n)
cm -m "a note on $ID2"
[ "$rc" != 0 ] && grep -qxF "message: $ID2 (board id)" <<< "$out" && [ "$(n)" = "$c" ] && ok "commit-msg: the repo check refuses although the global hook would pass" || bad "repo commit-msg: rc=$rc $out"
cm --no-verify -m "an old note on $ID3"; S=$(git -C "$R" rev-parse --short=7 HEAD)
fresh
push origin main
[ "$rc" != 0 ] && grep -qxF "commit $S: $ID3 (board id)" <<< "$out" && [ "$(ran pre-push)" = 0 ] && ok "pre-push: the repo check refuses although the global hook would pass (and stops before it)" || bad "repo pre-push: rc=$rc $out"
git -C "$R" reset -q --hard HEAD~1

echo "== the user's global core.hooksPath is honoured over the XDG default"
GH2="$T/elsewhere"; mkdir -p "$GH2"; cp "$GH/pre-commit" "$GH2/pre-commit"
printf '[core]\n\thooksPath = ~/../elsewhere\n' > "$HOME/.gitconfig"   # $HOME is $T/home, so ~/../elsewhere is $GH2
export GFAIL="pre-commit"; fresh
cm -m "fifth commit"
[ "$rc" != 0 ] && grep -qF "global pre-commit: refused" <<< "$out" && ok "a global core.hooksPath (with a leading ~) is where the global hook is looked up" || bad "global hooksPath: rc=$rc $out"
chmod -x "$GH/pre-commit"   # the XDG one would pass, the configured one decides
unset GFAIL; fresh
cm -m "fifth commit"
[ "$rc" = 0 ] && [ "$(ran pre-commit)" = 1 ] && ok "the XDG directory is not read once a global core.hooksPath names another" || bad "hooksPath wins: rc=$rc $out"

echo "== a global setting that points back at the repo's own hooks does not loop"
printf '[core]\n\thooksPath = %s\n' "$TREE/.githooks" > "$HOME/.gitconfig"
out=$(timeout 20 git -C "$R" commit -q --allow-empty -m "sixth commit" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "the global path being the repo's own hooks directory: the hooks run once and the commit goes through" || bad "loop guard: rc=$rc $out"
rm -f "$HOME/.gitconfig"

[ "$fail" = 0 ] && echo "githooks-chain: pass" || echo "githooks-chain: FAIL"
exit $fail
