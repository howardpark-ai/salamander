#!/usr/bin/env bash
# tests/suitemap.sh — which suites a change needs (Tue Oct 27th 2026). A tool, not a suite: tests/run.sh skips it.
# Every pull request that touched anything outside web/ used to run all ~49 tests/*.sh suites (~2 min on the CI box, the
# runner busy for every docs fix). tests/suites.map records, per suite, the tracked files it opens when it runs; a PR now
# runs the suites that open the files it changes, and a merge-queue entry runs the full set, so a miss here is caught in
# the queue (tests.yml). The map is MEASURED, not written: --measure runs the suites under strace and records what they open.
# Usage: bash tests/suitemap.sh --measure [-j N] [-T secs] [suite…]   (no suite named: every suite, as tests/run.sh would run)
#        bash tests/suitemap.sh --check
#        bash tests/suitemap.sh --select <from> <to>
#   --measure   runs each suite under `strace -f -y` (open, openat, openat2), keeps the paths that are tracked files of this
#               checkout, drops the `full` files and the suite's own tests/<name>.sh, and rewrites ONLY that suite's `suite`
#               line in tests/suites.map (the header and the hand-written full/none/text/firstline lines stay). For a
#               `firstline` suite the files that match `none` are dropped too: tests/syntax.sh reads the first line of EVERY tracked file (its
#               shebang test), which says nothing about whether a docs change matters to it. -j N: at most N suites at once
#               (default 1; the traced suites are slow and start thousands of processes: keep the box's load moderate).
#               -T: `timeout` per suite (default 900 s). A suite that exits non-zero under strace (a timing check can fail
#               when traced) gets a warning that its set may be partial; its line is written all the same. A file only
#               TRACKED counts: `git add` a new file before measuring. Needs strace (exit 2 when missing).
#   --check     the honesty check, fast (git and bash builtins only: no strace, no suite run). Exit 1 with one line per
#               problem and the fix: every suite has exactly one `suite` line and no line is left for a suite that is gone; every
#               tracked file outside web/ and .github/ is `full`, `none` or named on a suite line; every file a line names is
#               tracked; every `text` and `firstline` name is a suite; no suite but a `firstline` one names a `none` file.
#   --select    prints ONE line to stdout: `all`, or the suite names to run separated by spaces (empty: none). The reason for each
#               changed file goes to stderr. The rules per changed file F (git diff --name-only <from> <to>), first match wins:
#                 1. F under .github/                 → all (the gate itself changed; running everything is what catches a wrong gate)
#                 2. F under web/                     → the suites whose line names F (usually none; the web job is changed.sh's)
#                 3. F is a shell file (*.sh, bin/salamander, or a sh/bash shebang, as syntax.sh decides) or *.py and every added
#                    and removed line of its diff is blank or a `#` comment (`#!` is not one; a mode change or a new or deleted
#                    file is not comment-only)       → the `text` suites only
#                 4. F matches a `full` pattern       → all
#                 5. F = tests/<suite>.sh, a suite    → that suite (and any suite whose line names it)
#                 6. F = tests/suites.map             → the suites whose `suite` line differs; any full/none/text/firstline change → all
#                 7. otherwise                        → the suites whose line names F in the map at <to> or at <from> (deleted and
#                                                       renamed files are named only at <from>)
#                 8. still nothing: F matches `none` → nothing; else → all (unmapped: --check fails such a PR anyway)
#               A <from> or <to> that does not resolve, or a map missing at either end, → all (as changed.sh counts a range it
#               cannot resolve). When the union is every suite the answer is `all`. The suites of the answer are those at <to>.
# SUITEMAP_ROOT=<dir> points the tool at another checkout (tests/ci.sh runs it against a throwaway repo); default: this one.
# SUITEMAP_MAPFILE=<file> makes --select read that file as the map at both ends: a what-if over past merges, whose own trees
# carry no map (the change that made the map tabulated its last 40 merges that way).
# tests/suites.map lines (the file's own header says the same): `full <glob>…`, `none <glob>…`, `text <suite>…`, `firstline <suite>…`,
# `suite <name> <file>…` (measured, one per suite, files sorted, never hand-edited). A glob is a bash `case` pattern on the
# repo-relative path, `*` matching `/` too.
set -u
LC_COLLATE=C   # the shell's own string order ([[ a > b ]]); the external sort gets LC_ALL=C where it runs
SELF=$(cd "$(dirname "$0")" && pwd)
ROOT=${SUITEMAP_ROOT:-$(cd "$SELF/.." && pwd -P)}
MAP="$ROOT/tests/suites.map"
# tests/<name>.sh that are tools, not suites. tests/run.sh and tests/count-procs.sh repeat this list in their own enumeration
# (`case "$n" in lib|run|count-procs|suitemap`): the three lists must agree, or a tool is run as a suite.
TOOLS="lib run count-procs suitemap"

g() { git -C "$ROOT" "$@"; }
has() { g cat-file -e "$1^{commit}" 2>/dev/null; }
is_tool() { case " $TOOLS " in *" $1 "*) return 0 ;; esac; return 1; }
list_suites() {  # [<rev>] → SUITES: the suites tracked now, or the ones at <rev> (git's own order: sorted)
    local f n; local -a lst=(); SUITES=()
    if [ $# -gt 0 ]; then mapfile -t lst < <(g ls-tree --name-only "$1" tests/ 2>/dev/null)
    else mapfile -t lst < <(g ls-files 'tests/*.sh'); fi
    for f in ${lst[@]+"${lst[@]}"}; do
        [[ $f == tests/*.sh && $f != tests/*/* ]] || continue
        n=${f#tests/}; n=${n%.sh}; is_tool "$n" || SUITES+=("$n")
    done
}
match_any() {  # <file> <space-separated globs> → 0 when a bash `case` glob matches (read -a does not expand them)
    local p; local -a ps; read -ra ps <<< "$2"
    for p in ${ps[@]+"${ps[@]}"}; do case $1 in $p) return 0 ;; esac; done
    return 1
}
parse_map() {  # <map text> <assoc array>: full/none/text/firstline → the words, joined; suite:<name> → its files; names → the suite names
    local -n _m=$2; local line kw; local -a w
    _m=()
    while IFS= read -r line || [ -n "$line" ]; do
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        read -ra w <<< "$line"; kw=${w[0]}
        case $kw in
            full|none|text|firstline) _m[$kw]="${_m[$kw]:+${_m[$kw]} }${w[*]:1}" ;;
            suite) [ -n "${w[1]:-}" ] || { _m[bad]+="$line"$'\n'; continue; }
                [ -z "${_m[suite:${w[1]}]+x}" ] && _m[names]="${_m[names]:+${_m[names]} }${w[1]}" || _m[dup:${w[1]}]=1
                _m[suite:${w[1]}]="${w[*]:2}" ;;
            *) _m[bad]+="$line"$'\n' ;;
        esac
    done <<< "$1"
}
suites_naming() {  # <assoc array> <file> → appends to SN the suites whose line names the file
    local -n _m=$1; local n
    for n in ${_m[names]:-}; do [[ " ${_m[suite:$n]} " == *" $2 "* ]] && SN+=("$n"); done
    return 0
}

# ---------------------------------------------------------------- --check
cmd_check() {
    local -A M=() isT=() named=() isS=(); local f n w problems=0 line
    local -a tracked
    [ -f "$MAP" ] || { echo "no tests/suites.map: write its header and its full/none/text/firstline lines, then bash tests/suitemap.sh --measure"; return 1; }
    parse_map "$(<"$MAP")" M
    list_suites; for n in "${SUITES[@]}"; do isS[$n]=1; done
    mapfile -d '' -t tracked < <(g ls-files -z)
    for f in "${tracked[@]}"; do isT[$f]=1; done
    p() { echo "$*"; problems=$((problems+1)); }
    while IFS= read -r line; do [ -n "$line" ] && p "unknown line: '$line': a line starts with full, none, text, firstline or suite"; done <<< "${M[bad]-}"
    # a. one suite line per suite, none for a suite that is gone
    for n in "${SUITES[@]}"; do
        [ -n "${M[suite:$n]+x}" ] || p "missing: no suite line for $n: measure it (bash tests/suitemap.sh --measure $n)"
        [ -z "${M[dup:$n]+x}" ] || p "duplicate: $n has more than one suite line: keep one (bash tests/suitemap.sh --measure $n rewrites the first)"
    done
    for n in ${M[names]:-}; do
        [ -n "${isS[$n]+x}" ] || p "extra: a suite line for $n but no tests/$n.sh: delete the line"
        for w in ${M[suite:$n]}; do
            named[$w]=1
            # c. every file a line names is tracked
            [ -n "${isT[$w]+x}" ] || p "stale: $w on $n's line: re-measure (bash tests/suitemap.sh --measure $n)"
            # e. a file that matches `none` is one no suite needs; a firstline suite opens everything to read line 1, the rest must not
            if [[ " ${M[firstline]-} " != *" $n "* ]] && match_any "$w" "${M[none]-}"; then
                p "none but used: $w is on $n's line and matches a none pattern: take it off none (a suite opens it), or re-measure $n if it no longer does"
            fi
        done
    done
    # b. every tracked file outside web/ and .github/ that is not a suite file is full, none, or named on a suite line
    for f in "${tracked[@]}"; do
        case $f in web/*|.github/*|tests/suites.map) continue ;; esac
        if [[ $f == tests/*.sh && $f != tests/*/* ]]; then n=${f#tests/}; n=${n%.sh}; [ -n "${isS[$n]+x}" ] && continue; fi
        match_any "$f" "${M[full]-}" && continue
        match_any "$f" "${M[none]-}" && continue
        [ -n "${named[$f]+x}" ] && continue
        p "unmapped: $f: measure the suites that use it (bash tests/suitemap.sh --measure <suite>…), or add it to none/full with a reason"
    done
    # d. a text or firstline name is a suite
    for n in ${M[text]-}; do [ -n "${isS[$n]+x}" ] || p "bad text name: $n is not a suite: fix the text line"; done
    for n in ${M[firstline]-}; do [ -n "${isS[$n]+x}" ] || p "bad firstline name: $n is not a suite: fix the firstline line"; done
    if [ "$problems" -gt 0 ]; then echo "suitemap: $problems problem(s)"; return 1; fi
    echo "suitemap: ok (${#SUITES[@]} suites, ${#named[@]} files named, ${#tracked[@]} tracked)"
}

# ---------------------------------------------------------------- --select
shellish() {  # <file> <rev>: *.sh, bin/salamander, *.py, or a sh/bash shebang on line 1 (syntax.sh decides the same way)
    case $1 in *.sh|bin/salamander|*.py) return 0 ;; esac
    local first=""; read -r first < <(g show "$2:$1" 2>/dev/null)
    [[ $first =~ ^#!.*[/\ ](ba)?sh(\ |$) ]]
}
comment_only() {  # <from> <to> <file>: the file changed in content only, and every added and removed line is blank or a # comment
    local line body hunks=0
    while IFS= read -r line; do
        if [[ $line == '@@'* ]]; then hunks=$((hunks+1)); continue; fi
        if [ "$hunks" = 0 ]; then   # the header: a mode change, a new or deleted file, a binary is not a comment
            case $line in 'old mode'*|'new mode'*|'new file mode'*|'deleted file mode'*|'Binary files'*|'GIT binary patch'*|'rename '*|'copy '*) return 1 ;; esac
            continue
        fi
        case $line in
            '\'*) continue ;;   # "\ No newline at end of file"
            [+-]*) body=${line:1}
                [[ $body =~ ^[[:space:]]*$ ]] && continue
                [[ $body == '#!'* ]] && return 1   # a shebang is code: it picks the interpreter
                [[ $body =~ ^[[:space:]]*'#' ]] && continue
                return 1 ;;
        esac
    done < <(g diff -U0 --no-renames "$1" "$2" -- "$3")
    [ "$hunks" -gt 0 ]
}
cmd_select() {
    local from="${1:?usage: suitemap.sh --select <from> <to>}" to="${2:?usage: suitemap.sh --select <from> <to>}"
    local -A MF=() MT=() sel=(); local tf tt F n why rev all=0 sh
    local -a files SN
    if ! has "$from" || ! has "$to"; then echo "  no range $from..$to in this checkout: everything" >&2; echo all; return 0; fi
    if [ -n "${SUITEMAP_MAPFILE:-}" ]; then   # a what-if: this map file stands for the map at both ends (the fraction a map would have saved over past merges)
        tf=$(<"$SUITEMAP_MAPFILE") || { echo all; return 0; }; tt=$tf
    else
        tf=$(g show "$from:tests/suites.map" 2>/dev/null) || { echo "  no tests/suites.map at $from: everything" >&2; echo all; return 0; }
        tt=$(g show "$to:tests/suites.map" 2>/dev/null) || { echo "  no tests/suites.map at $to: everything" >&2; echo all; return 0; }
    fi
    parse_map "$tf" MF; parse_map "$tt" MT
    list_suites "$to"
    local -A atTo=(); for n in "${SUITES[@]}"; do atTo[$n]=1; done
    mapfile -d '' -t files < <(g diff -z --name-only --no-renames "$from" "$to")
    pick() { local x; for x in "$@"; do [ -n "${atTo[$x]+x}" ] && sel[$x]=1; done; return 0; }   # only a suite that exists at <to> can run
    for F in ${files[@]+"${files[@]}"}; do
        SN=()
        if [[ $F == .github/* ]]; then all=1; why="under .github/: the gate itself changed, everything runs"
        elif [[ $F == web/* ]]; then
            suites_naming MF "$F"; suites_naming MT "$F"; pick ${SN[@]+"${SN[@]}"}; why="under web/: the suites that name it (${SN[*]:-none})"
        elif { rev=$to; g cat-file -e "$to:$F" 2>/dev/null || rev=$from; shellish "$F" "$rev"; } && comment_only "$from" "$to" "$F"; then
            pick ${MT[text]-}; why="comments and blank lines only: the text suites (${MT[text]:-none})"
        elif match_any "$F" "${MT[full]-}"; then all=1; why="a full file: everything runs"
        elif [[ $F == tests/*.sh && $F != tests/*/* ]] && n=${F#tests/} && n=${n%.sh} && [ -n "${atTo[$n]+x}" ]; then
            suites_naming MF "$F"; suites_naming MT "$F"; pick "$n" ${SN[@]+"${SN[@]}"}; why="the suite itself, and the suites that name it (${SN[*]:-none})"
        elif [ "$F" = tests/suites.map ]; then
            if [ "${MF[full]-}" != "${MT[full]-}" ] || [ "${MF[none]-}" != "${MT[none]-}" ] || [ "${MF[text]-}" != "${MT[text]-}" ] || [ "${MF[firstline]-}" != "${MT[firstline]-}" ]; then
                all=1; why="the map's full, none, text or firstline line changed: everything runs"
            else
                for n in "${SUITES[@]}"; do [ "${MF[suite:$n]-@unset@}" != "${MT[suite:$n]-@unset@}" ] && { sel[$n]=1; SN+=("$n"); }; done
                why="the map's suite lines that changed (${SN[*]:-none})"
            fi
        else
            suites_naming MF "$F"; suites_naming MT "$F"
            if [ ${#SN[@]} -gt 0 ]; then pick "${SN[@]}"; why="named by the suites ${SN[*]}"
            elif match_any "$F" "${MT[none]-}"; then why="a none file: no suite needs it"
            else all=1; why="named by no suite and not none (unmapped): everything runs"; fi
        fi
        echo "  $F: $why" >&2
    done
    if [ "$all" = 1 ] || { [ ${#SUITES[@]} -gt 0 ] && [ ${#sel[@]} -eq ${#SUITES[@]} ]; }; then echo all; return 0; fi
    sh=""; for n in "${SUITES[@]}"; do [ -n "${sel[$n]+x}" ] && sh="${sh:+$sh }$n"; done
    echo "$sh"
}

# ---------------------------------------------------------------- --measure
map_set_suite() {  # <suite> <file>…: rewrite that suite's line in the map, or insert it among the suite lines in sorted place
    local s="$1" new line i out_done=0 last=-1 first_bigger=-1 x; shift
    new="suite $s${*:+ $*}"
    local -a lines out=() ; local lockfd
    # two --measure runs (two sessions, a slow suite measured on its own) rewrite different lines of one file: read, change and
    # replace it under a lock on the tests/ directory (not on the map: the replace swaps its inode)
    exec {lockfd}< "$ROOT/tests"; flock "$lockfd"
    mapfile -t lines < "$MAP"
    for i in "${!lines[@]}"; do
        line=${lines[$i]}
        [[ $line == 'suite '* ]] || continue
        x=${line#suite }; x=${x%% *}; last=$i
        [ "$x" = "$s" ] && { out_done=1; lines[$i]=$new; break; }
        [ "$first_bigger" = -1 ] && [[ $x > $s ]] && first_bigger=$i
    done
    if [ "$out_done" = 0 ]; then
        if [ "$first_bigger" != -1 ]; then i=$first_bigger; elif [ "$last" != -1 ]; then i=$((last+1)); else i=${#lines[@]}; fi
        out=("${lines[@]:0:i}" "$new" "${lines[@]:i}"); lines=("${out[@]}")
    fi
    printf '%s\n' "${lines[@]}" > "$MAP.new.$$" && mv "$MAP.new.$$" "$MAP"
    exec {lockfd}<&-   # closing the descriptor drops the lock
}
cmd_measure() {
    local JOBS=1 LIMIT=900 f n s
    while [ $# -gt 0 ]; do
        case "$1" in
            -j) JOBS="${2:?-j needs a number}"; shift 2 ;;
            -j*) JOBS="${1#-j}"; shift ;;
            -T) LIMIT="${2:?-T needs seconds}"; shift 2 ;;
            -*) echo "suitemap.sh: unknown option $1" >&2; return 2 ;;
            *) break ;;
        esac
    done
    case "$JOBS" in ''|*[!0-9]*|0) echo "suitemap.sh: -j takes a number above 0" >&2; return 2 ;; esac
    command -v strace >/dev/null || { echo "suitemap.sh: --measure needs strace (not installed); install it, or measure on a box that has it" >&2; return 2; }
    [ -f "$MAP" ] || { echo "suitemap.sh: no tests/suites.map: write its header and its full/none/text lines first" >&2; return 2; }
    local -a suites=()
    if [ $# -gt 0 ]; then suites=("$@")
    else for f in "$ROOT"/tests/*.sh; do n=$(basename "$f" .sh); is_tool "$n" || suites+=("$n"); done; fi
    for s in "${suites[@]}"; do [ -f "$ROOT/tests/$s.sh" ] || { echo "suitemap.sh: no suite tests/$s.sh" >&2; return 2; }; is_tool "$s" && { echo "suitemap.sh: $s is a tool, not a suite" >&2; return 2; }; done
    local -A MM=() isT=(); local -a tracked
    parse_map "$(<"$MAP")" MM
    mapfile -d '' -t tracked < <(g ls-files -z); for f in "${tracked[@]}"; do isT[$f]=1; done
    D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
    # an interrupt (a `timeout` around this tool, Ctrl-C) takes the running suites down with it: a suite left behind would go on
    # for minutes against a temp dir that no longer exists, loading the box (the suite's own EXIT trap removes its tmux server)
    killtree() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do killtree "$c"; done; kill -TERM "$1" 2>/dev/null; return 0; }
    trap 'for c in $(pgrep -P $$); do killtree "$c"; done; exit 143' TERM INT
    local -a started=() done_=()
    start() {  # <suite>: in the background; its trace is cut down to the opened paths under ROOT, then the rc and seconds land
        local s="$1"
        ( t=$(printf '%(%s)T' -1)
          timeout -k 5 "$LIMIT" strace -f --seccomp-bpf -qq -y -e trace=open,openat,openat2 -e status=successful -o "$D/$s.trace" \
              bash "$ROOT/tests/$s.sh" > "$D/$s.out" 2>&1 < /dev/null
          rc=$?
          # -y writes the returned fd as `= 3</abs/path>`: a socket, pipe or anon inode is not under ROOT and drops out here
          grep -aF "<$ROOT/" "$D/$s.trace" | sed -n 's/^.*) = [0-9]*<\(.*\)>$/\1/p' | LC_ALL=C sort -u > "$D/$s.opened"
          rm -f "$D/$s.trace"; tail -n 1 "$D/$s.out" > "$D/$s.last"   # the suite's own verdict line says whether it ran to its end
          echo "$rc $(( $(printf '%(%s)T' -1) - t ))" > "$D/$s.rc" ) </dev/null &
    }
    running() { local s n=0; for s in ${started[@]+"${started[@]}"}; do [ -e "$D/$s.rc" ] || n=$((n+1)); done; echo "$n"; }
    harvest() {  # the suites that ended since the last call: their files into the map, one line each on the screen
        local s rc secs rel o isfirst warn; local -a files
        for s in "${suites[@]}"; do
            [ -e "$D/$s.rc" ] || continue; case " ${done_[*]-} " in *" $s "*) continue ;; esac
            done_+=("$s"); read -r rc secs < "$D/$s.rc"; files=()
            match_any "$s" "${MM[firstline]-}" && isfirst=1 || isfirst=0
            while IFS= read -r o; do
                rel=${o#"$ROOT"/}
                [ -n "${isT[$rel]+x}" ] || continue                       # tracked files only: a directory, a temp file, __pycache__ drop out
                [ "$rel" = "tests/$s.sh" ] && continue                     # a suite's own file: its change selects it by rule 5
                match_any "$rel" "${MM[full]-}" && continue                # a full file selects everything already
                [ "$isfirst" = 1 ] && match_any "$rel" "${MM[none]-}" && continue   # read only to look at its first line
                files+=("$rel")
            done < "$D/$s.opened"
            map_set_suite "$s" ${files[@]+"${files[@]}"}
            warn=""; [ "$rc" = 0 ] || warn="  WARNING: exit $rc under strace, its set may be partial (re-measure it alone; its last line: $(<"$D/$s.last"))"
            printf '  %-20s rc=%-3s %4ss %4d file(s)%s\n' "$s" "$rc" "$secs" "${#files[@]}" "$warn"
        done
    }
    for s in "${suites[@]}"; do
        while [ "$(running)" -ge "$JOBS" ]; do wait -n 2>/dev/null || sleep 0.5; harvest; done
        start "$s"; started+=("$s")
    done
    while [ "$(running)" -gt 0 ]; do wait -n 2>/dev/null || sleep 0.5; harvest; done
    wait; harvest
    echo "suitemap: measured ${#suites[@]} suite(s) into tests/suites.map"
}

case "${1:-}" in
    --measure) shift; cmd_measure "$@"; exit $? ;;
    --check) cmd_check; exit $? ;;
    --select) shift; cmd_select "$@"; exit $? ;;
    -h|--help) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "usage: suitemap.sh --measure [-j N] [-T secs] [suite…] | --check | --select <from> <to>" >&2; exit 2 ;;
esac
