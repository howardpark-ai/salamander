#!/usr/bin/env bash
# tests/help-gates.sh — the two help-text gates' own tests, each on a DELIBERATE DRIFT. The gates themselves:
#   check 1  tests/help-snapshot.sh         sala's help text against the committed snapshot (a suite of its own)
#   check 2  .github/scripts/skills-flags.py (+ tests/skills-flags.sh)   the verbs and flags the skills files name exist in the help
# 1. a copy of bin/ and lib/ in another directory with one help line edited (top-level, then a verb's own usage): the snapshot
#    check fails with the unified diff and the one-line fix, `--update` into a throwaway snapshot makes it pass; the unedited copy
#    passes from its other path (the paths are normalised, nothing else varies); an unprobed verb is listed, not failed.
# 2. fixture help text and fixture skills: a good mention passes, a new unmentioned flag only WARNs, a stale flag and a removed verb
#    FAIL naming skill file:line, prose / pipes / quoted words are not read; with no skills directory the check SKIPs (exit 0);
#    the real regenerated help against a fixture skills directory with a stale `sala lane` flag fails.
# Usage: bash tests/help-gates.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
T=$(mktemp -d); export HOME=$T/home; mkdir -p "$HOME"
trap 'rm -rf "$T"' EXIT
SNAPSH="$ROOT/tests/help-snapshot.sh"; SKIPY="$ROOT/.github/scripts/skills-flags.py"

echo "== check 1: the help snapshot"
C=$T/copy; mkdir -p "$C"; cp -r "$ROOT/bin" "$ROOT/lib" "$C/"
out=$(HELP_SNAPSHOT_ROOT="$C" bash "$SNAPSH" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "a copy of the tree in another directory matches the committed snapshot (paths normalised)" || bad "the copy drifted by itself: rc=$rc $(echo "$out" | head -20)"
a=$(bash "$SNAPSH" --generate); b=$(bash "$SNAPSH" --generate)
[ "$a" = "$b" ] && ok "two generations are byte for byte the same" || bad "the generation is not deterministic"
case "$a" in *"$ROOT"*|*"$T"*|*"$HOME"*) bad "the generated text holds a checkout or temporary path" ;; *) ok "no checkout path, temporary path or HOME in the text" ;; esac
grep -q '^### verbs with no help path of their own.*spawn' <<< "$a" && ok "a verb with no safe help path (spawn) is listed, not probed" || bad "the unprobed verbs are not listed"

sed -i 's/rename a live pane end to end/rename a live pane from start to end/' "$C/bin/salamander"
out=$(HELP_SNAPSHOT_ROOT="$C" bash "$SNAPSH" 2>&1); rc=$?
[ "$rc" = 1 ] && ok "a top-level help line edited: the check fails" || bad "drift not caught: rc=$rc"
grep -q '^    -.*rename a live pane end to end' <<< "$out" && grep -q '^    +.*rename a live pane from start to end' <<< "$out" && ok "the failure prints the unified diff (old and new line)" || bad "no diff in: $out"
grep -q 'bash tests/help-snapshot.sh --update' <<< "$out" && ok "and the one-line fix" || bad "no fix line"
cp "$ROOT/tests/help-snapshot.txt" "$T/snap.txt"
HELP_SNAPSHOT_ROOT="$C" HELP_SNAPSHOT_FILE="$T/snap.txt" bash "$SNAPSH" --update >/dev/null 2>&1
out=$(HELP_SNAPSHOT_ROOT="$C" HELP_SNAPSHOT_FILE="$T/snap.txt" bash "$SNAPSH" 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q 'from start to end' "$T/snap.txt" && ok "--update rewrites the snapshot, and the check then passes" || bad "--update did not fix it: rc=$rc"

sed -i 's/^usage="usage: salamander restore (NAME… | --missing) \[--dry-run\]"/usage="usage: salamander restore (NAME… | --missing | --all) [--dry-run]"/' "$C/lib/restore.sh"
out=$(HELP_SNAPSHOT_ROOT="$C" HELP_SNAPSHOT_FILE="$ROOT/tests/help-snapshot.txt" bash "$SNAPSH" 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q '^    +usage: salamander restore (NAME… | --missing | --all) \[--dry-run\]' <<< "$out" && ok "a verb's own usage edited (restore): caught in its section" || bad "a verb's usage drift is not caught: rc=$rc $(echo "$out" | head -12)"
out=$(HELP_SNAPSHOT_ROOT="$T/none" bash "$SNAPSH" 2>&1); [ "$?" = 1 ] && ok "a root with no sala fails, never passes silently" || bad "a missing root passed"

echo "== check 2: the skills name only flags the help has"
cat > "$T/help.txt" <<'EOF'
### sala --help (exit 0)
usage text

  salamander foo [--alpha] [--beta]   do foo
                                     (--gamma: more)
  salamander bar NAME [--delta]       do bar

### sala foo --help (exit 0)
usage: salamander foo [--alpha] [--beta] [--epsilon]

### verbs with no help path of their own (listed, not probed; their usage is the sala --help text above): bar
EOF
S=$T/skills; mkdir -p "$S/good" "$S/stale"
cat > "$S/good/SKILL.md" <<'EOF'
---
name: good
---
Run `sala foo --alpha` first, or `~/.local/bin/sala foo --gamma` in a pinch.
Prose: sala foo --nonexistent is not read, and `sala foo --alpha | grep --nonexistent` stops at the pipe.
Quoted: `sala bar X --delta "do --nonexistent now"`.
```bash
$ sala bar NAME --delta   # a comment
FOO=1 sala foo --beta && echo --nonexistent
```
EOF
out=$(python3 -I "$SKIPY" "$T/help.txt" "$S" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "a good skill passes (inline span, path prefix, fenced block, pipe, quotes and prose left alone)" || bad "good skill failed: $out"
grep -q '^WARN sala foo: .*--epsilon' <<< "$out" && ! grep -q '^FAIL' <<< "$out" && ok "a flag in the help that no skill mentions (--epsilon) only WARNs" || bad "no WARN for the unmentioned flag: $out"
cat > "$S/stale/SKILL.md" <<'EOF'
line two
Use `sala foo --alpha --removed` to do it.
```
sala frobnicate --alpha
```
EOF
out=$(python3 -I "$SKIPY" "$T/help.txt" "$S" 2>&1); rc=$?
[ "$rc" = 1 ] && ok "a stale flag and a removed verb: the check fails" || bad "stale skill passed: rc=$rc"
grep -q '^FAIL stale/SKILL.md:2 .*--removed' <<< "$out" && ok "FAIL names the skill file and line, and the flag" || bad "no file:line for the stale flag: $out"
grep -q '^FAIL stale/SKILL.md:4 .*frobnicate' <<< "$out" && ok "FAIL names the removed verb, file and line" || bad "no verb FAIL: $out"
! grep -q 'good/SKILL.md' <<< "$(grep '^FAIL' <<< "$out")" && ok "the good file is not blamed" || bad "good file blamed"

out=$(SKILLS_DIR="$T/no-such-dir" bash "$ROOT/tests/skills-flags.sh" 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q 'SKIP' <<< "$out" && ok "no skills directory: SKIP with a message, exit 0" || bad "missing skills dir: rc=$rc $out"
out=$(env -u SKILLS_DIR bash "$ROOT/tests/skills-flags.sh" 2>&1); rc=$?   # HOME is the empty temporary one; no directory is looked for by itself
[ "$rc" = 0 ] && grep -q 'SKIP' <<< "$out" && ok "SKILLS_DIR unset: SKIP, exit 0 (no default location is searched)" || bad "no SKILLS_DIR: rc=$rc $out"
mkdir -p "$HOME/.claude/plugins/synced/demo/skills/x"   # a plugin copy where a default search would have looked: it must stay unread
echo '`sala lane --removed-flag`' > "$HOME/.claude/plugins/synced/demo/skills/x/SKILL.md"
out=$(env -u SKILLS_DIR bash "$ROOT/tests/skills-flags.sh" 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q 'SKIP' <<< "$out" && ok "a plugin copy under ~/.claude/plugins is not read unless SKILLS_DIR names it" || bad "plugin copy read: rc=$rc $out"
mkdir -p "$T/skills-new/x"
echo '`sala lane --removed-flag`' > "$T/skills-new/x/SKILL.md"
out=$(SKILLS_DIR="$T/skills-new" bash "$ROOT/tests/skills-flags.sh" 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q "skills-new" <<< "$out" && grep -q '^FAIL x/SKILL.md:1 .*--removed-flag' <<< "$out" && ok "SKILLS_DIR is read, and the real regenerated help rejects its stale flag" || bad "SKILLS_DIR: rc=$rc $out"
echo '`sala lane --list` and `sala model --effort X`' > "$T/skills-new/x/SKILL.md"
out=$(SKILLS_DIR="$T/skills-new" bash "$ROOT/tests/skills-flags.sh" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "real flags of the real help pass" || bad "real flags failed: $out"

[ "$fail" = 0 ] && echo "help-gates: pass" || echo "help-gates: FAIL"
exit $fail
