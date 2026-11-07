#!/usr/bin/env bash
# tests/skills-flags.sh — check 2 of the help-text gates: the skill files may only name sala verbs and
# flags that sala's help has. The help is regenerated from this checkout (tests/help-snapshot.sh --generate), so a PR that
# removes or renames a flag fails here when the skills still teach it; the parser is .github/scripts/skills-flags.py.
#   FAIL <skill file>:<line> ...   a verb or flag a skill names that the help does not have: the suite fails
#   WARN ...                       a flag in the help that no skill mentions: printed, never fails
# Skills location: $SKILLS_DIR only (no default location is searched). No skills directory (SKILLS_DIR unset, or a CI runner
# without the plugin): SKIP with a message and exit 0, never a failure.
# The fixture cases (a good mention, a stale flag, a new unmentioned flag) are in tests/help-gates.sh.
# Usage: bash tests/skills-flags.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
dir=${SKILLS_DIR:-}
if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    echo "  SKIP no skills directory (SKILLS_DIR unset or not a directory): nothing to check"
    echo "skills-flags: skipped"
    exit 0
fi
help=$(mktemp) || exit 1; trap 'rm -f "$help"' EXIT
bash "$ROOT/tests/help-snapshot.sh" --generate > "$help" || { echo "  FAIL could not regenerate the help text"; exit 1; }
echo "  skills: $dir"
python3 -I "$ROOT/.github/scripts/skills-flags.py" "$help" "$dir"; rc=$?
[ "$rc" = 0 ] && echo "skills-flags: pass" || echo "skills-flags: FAIL"
exit $rc
