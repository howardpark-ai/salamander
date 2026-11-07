#!/usr/bin/env bash
# Every tracked shell file parses (`bash -n`): *.sh, bin/salamander, and anything whose first line is a sh/bash shebang;
# the tracked Python files parse too. The same file list deploy.sh checks before it fast-forwards production.
# Usage: bash tests/syntax.sh   (exit 0 = pass; a second or two)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
fail=0; n=0
while IFS= read -r f; do
    case "$f" in
        *.sh|bin/salamander) ;;
        *.py) if python3 -c 'import ast,sys; ast.parse(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1])' "$f"; then echo "  ok   $f (python)"; else echo "  FAIL $f (python)"; fail=1; fi; continue ;;
        *) first=$(sed -n 1p "$f" 2>/dev/null); [[ "$first" =~ ^#!.*[/\ ](ba)?sh(\ |$) ]] || continue ;;
    esac
    n=$((n+1))
    if out=$(bash -n "$f" 2>&1); then echo "  ok   $f"; else echo "  FAIL $f: $out"; fail=1; fi
done < <(git ls-files)
[ "$n" -gt 0 ] || { echo "  FAIL no shell files found (not a git checkout?)"; fail=1; }
# Lint: a test never kills claude by name. A line of a tests/*.sh that pgreps claude and kills (or pkill/killall claude) must be
# the guarded form (kill_fake_claude from tests/lib.sh, or the exe check `-ef "/proc/$p/exe"` against the test's own fake); the guard.sh
# `expect` lines only name such commands as text for the hook to refuse. An unguarded one took down every pane on the coordinator machine (Oct 28th 2026).
lint=0
while IFS= read -r f; do
    [ "$f" = tests/syntax.sh ] && continue   # (this lint's own pattern)
    while IFS= read -r l; do
        body=${l#*:}
        [[ $body =~ ^[[:space:]]*(expect|#) ]] && continue   # a comment, or a guard.sh line that only names the command as text
        [[ $body == *kill_fake_claude* || $body == *'-ef "/proc/'* ]] && continue
        [[ $body == *kill* ]] || continue
        echo "  FAIL $f:${l%%:*}: unguarded kill of claude by name (use kill_fake_claude from tests/lib.sh)"; fail=1; lint=$((lint+1))
    done < <(grep -nE '(pgrep[^|;)]*claude|pkill[^|;]*claude|killall[^|;]*claude)' "$f" 2>/dev/null)
done < <(git ls-files 'tests/*.sh')
[ "$lint" = 0 ] && echo "  ok   no unguarded kill of claude by name in tests/*.sh"
# Exact session targets (lib/common.sh, EXACT TMUX SESSION TARGETS): a tmux call never targets a session variable bare. A plain
# `-t "$name"` reads a number as the caller's window index and prefix-matches an unmatched name (`sala retire 0` named the
# caller's own pane). The target is `=NAME` (tmux_sess_t) or `=NAME:` (tmux_win_t) or a pane id; this lists the variable
# names sala uses for a session. A line that is a comment, or one in the text of a message (`tmux attach -t =$NAME`), is fine.
tl=0
while IFS= read -r l; do
    body=${l#*:}
    [[ $body =~ ^[[:space:]]*# ]] && continue
    echo "  FAIL ${l%%:*}: a tmux target that is a bare session name (use tmux_sess_t or tmux_win_t, lib/common.sh): $(echo "${l#*:}" | sed 's/^[[:space:]]*//' | cut -c1-110)"; fail=1; tl=$((tl+1))
done < <(grep -nE 'tmux[^|;]* -t "?\$\{?(name|NAME|sess|SESS|SESSION|session|master|MASTER|SALA_MASTER|SALA_RC_SESSION|OLD|NEW|new|target|sb)\}?"?([ )]|$)' lib/*.sh bin/salamander 2>/dev/null)
[ "$tl" = 0 ] && echo "  ok   no tmux target that is a bare session name in lib/*.sh and bin/salamander"
# Commands for the owner: text in lib/, bin/ and docs/ that hands the owner a command to type
# gives it for sala's own Shell (the web UI's Shell button): bare for this machine, `ssh <host> '<command>'` for another, typed in that
# same Shell. It never sends the owner to a Windows terminal or PowerShell, to a terminal on their own PC, or to ssh in to the sala
# host first (`ssh <host> sala ...` as a wrapper for a command meant for the sala host itself).
sc=0
while IFS= read -r l; do
    where=${l%%:*}; rest=${l#*:}; where="$where:${rest%%:*}"; text=${rest#*:}
    echo "  FAIL $where: tells the owner to use a Windows terminal or PowerShell, their own PC, or to ssh in first (give the command for the web UI's Shell): $(echo "$text" | sed 's/^[[:space:]]*//' | cut -c1-110)"; fail=1; sc=$((sc+1))
done < <(git ls-files -z -- lib bin docs | xargs -0 grep -nHI -i -E 'windows terminal|windows (shell|console|command prompt)|powershell (window|prompt|terminal)|(in|into|from|open|use|using) (a |an |your |the )?(powershell|pwsh)\b|your (own )?pc\b|ssh [^ ]+ (sala|salamander)( |$)' 2>/dev/null)
[ "$sc" = 0 ] && echo "  ok   no text in lib/, bin/ or docs/ sends the owner to a Windows terminal, PowerShell or an ssh hop for a command of the sala host"
# Scratch before its trap: a suite's temp HOME (`HOME=$(mktemp -d)`) is removed by an EXIT trap, which is often set a few lines later
# (after the fake claude is compiled and the HOME locked). An exit between the two leaves a bare `tmp.XXXXXXXXXX` in the runner's temp
# folder (a failed `cc`, a `flock -n` that does not take): so a `cc -o` or `flock -n` line that exits, between a suite's mktemp and its
# first EXIT trap, removes the HOME itself (`|| { rm -rf "$HOME"; exit 1; }`).
ps=0
while IFS= read -r l; do
    echo "  FAIL ${l%%:*}: an exit between the temp HOME and the EXIT trap leaves the folder (use || { rm -rf \"\$HOME\"; exit 1; }): $(echo "${l#*:}" | cut -c1-110)"; fail=1; ps=$((ps+1))
done < <(awk 'FNR==1 {m=0} /=\$\(mktemp/ {m=1} /trap .*EXIT/ {m=0} m && /(^|; *)(cc -o|exec [0-9]+< [^;]*; *flock -n) .*\|\| *exit/ && !/rm -rf/ {print FILENAME ":" FNR ":" $0}' tests/*.sh)
[ "$ps" = 0 ] && echo "  ok   no exit between a suite's temp HOME and its EXIT trap leaves the folder"
echo "syntax: $n shell file(s) checked, $([ $fail = 0 ] && echo pass || echo FAIL)"
exit $fail
