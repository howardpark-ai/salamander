# lib/provision.sh — provision the whole fleet from the coordinator machine: every box's deterministic steps, then the recycle.
#
#   salamander provision [--check] [--session] [--no-recycle] [--only STEP[,STEP…]] [--quiet] [HOST…]
#       no HOST: every SALA_FLEET_HOSTS box, then this one, then `recycle --update --force` (the master's last act)
#       HOST…:   just those boxes, this one included when named (no recycle)
#       --check: every box read-only (the scripts' check mode); changes nothing
#       --only:  just these steps of the step scripts, on every box (or the named ones): the apply, then a check of the
#                same steps, one fleet post; never the CLI update, a provision set or a recycle. A name no step script
#                lists (their --list) is refused before any box is touched. With --check: only the check. ("settings" on every box was once done by hand: sala could not run one step.) `repo` (the
#                checkout's fast-forward) is always included and runs first, the other steps read the checkout
#       --quiet: no fleet post (with --only or --check): the caller reports — lib/settings-apply.sh, which also
#                names SALA_PROVISION_RESULT_DIR to keep the result dir (each box's STEP lines, the check's too, and its mark)
#       --session: also the old headless /provision session per remote box, after the steps (every
#                  item is a script step or reports `manual`, so the session is opt-in — it can fix nothing a script
#                  does not, and a `manual` item needs the owner, not a model)
#   salamander provision --settle <set> <host> <step> ok|gave ["<note>"]   (the master) an item of a provision set is done,
#       or given up; the note is the plain words the set's post shows ("repo back in step with GitHub")
#   salamander provision --waiting <set> <host> <step> "<id> is waiting on your OK in <session>"   (the master) the item
#       waits on the owner: the text stands in for its detail in the set's later posts
#   salamander provision --sets          the open provision sets, their boxes and items
#   salamander provision --retry-worker <set>   (internal) the set's retry worker for its failed steps
#
# PROVISION SETS (common.sh, "provision sets"): a run that leaves something on a box — a failed
# step, a `manual` one, a box offline — is a set with the recycle set's follow-up: a failed step is retried, a manual one
# of kind `session` goes to the master to fix and settle, one of kind `owner` goes to the master to file on the board and
# record with --waiting, an offline box is provisioned once it is back; every later post names the set and counts boxes
# OK. A clean run keeps its single fleet post. The run's own --session mode keeps the old fleet post and makes no set.
#
# Every deterministic step, for the coordinator and the others, is code: the steps live once in
# the ops repo's provision step scripts (one for every box, one for Linux). The fleet is Linux and macOS: the
# PowerShell stage for Windows boxes was retired with Thu Oct 15th 2026, sala off Windows; a
# SALA_PROVISION_STEPS_PWSH key still in a config is ignored.
# What follows is the history of the headless-session path, kept for --session.
#
# For each host that answers (a sleeping one is "offline, skipped", not a failure), runs
#     ssh <host> 'claude --dangerously-skip-permissions -p "/provision"'
# all hosts in parallel; the full output lands in $SALA_LOG_DIR/salamander-provision-<host>.log. The prompt asks the
# run to end with one fixed line, `SALA-SUMMARY: <OK | N fixed (…) · N needs you (…) · N failed (…)>`, and the report
# (terminal + one Slack post, one host per line with a status mark) carries that line, or "see log" when it is
# missing (the last free-form line — "…Did it work?" — made the post unreadable).
#
# Why it lives in sala: the remote command spawns a headless agent with permissions skipped, which
# auto mode's classifier rightly refuses unless that exact command is pre-approved — and the per-host
# allow rules went stale at the fleet rename. One allow rule for `sala` covers every
# host, current and future; the host list lives in the config, not in permission rules.

# the set verbs: state edits and the set's own worker, not an operation — no ops guard, no fleet run
case "${1:-}" in
    --settle)
        [ $# -ge 5 ] && case "$5" in ok|gave) true;; *) false;; esac || die "usage: salamander provision --settle <set> <host> <step> ok|gave [\"<note>\"]"
        _set_locked _pset_settle "$2" "$3" "$4" "$5" "${6:-}"; exit $? ;;
    --waiting)
        [ $# -ge 5 ] && [ -n "$5" ] || die "usage: salamander provision --waiting <set> <host> <step> \"<id> is waiting on your OK in <session>\""
        _set_locked _pset_waiting "$2" "$3" "$4" "$5"; exit $? ;;
    --sets)
        n=0; for id in $(pset_open); do n=$((n+1))
            echo "set $id · Provision $(set_val "$id" label) · $(set_val "$id" done)/$(set_val "$id" total) OK$(pset_worker_live "$id" && echo ' · retry worker running')"
            for h in $(set_vals "$id" out); do grep -qxF "offline=$h" "$SALA_SET_DIR/$id" && echo "  $h: offline, provisioned once it is back"
                _pset_items "$id" "$h" | while IFS='|' read -r _ st kind _ _ det; do w=$(_pset_wait "$id" "$h" "$st"); echo "  $h $st [$kind]: $det${w:+ — $w}"; done
            done
        done; [ "$n" = 0 ] && echo "no open provision sets"; exit 0 ;;
    --retry-worker)
        id="${2:-}"; set_has "$id" || die "no provision set '$id'"
        pidf="$SALA_LOG_DIR/salamander-pretry.$id.pid"; pset_worker_live "$id" && exit 0
        echo $$ > "$pidf"; trap 'rm -f "$pidf"' EXIT
        deadline=$(( $(date +%s) + SALA_RETRY_WINDOW ))
        pset_log "set $id: retry worker — every $(dur_words "$SALA_RETRY_EVERY") for up to $(dur_words "$SALA_RETRY_WINDOW")"
        while [ "$(date +%s)" -lt "$deadline" ]; do
            sleep "$SALA_RETRY_EVERY"
            [ "$(set_val "$id" closed)" = 1 ] && break
            hosts=$(_pset_failed_hosts "$id" | tr '\n' ' '); [ -n "${hosts// /}" ] || break
            pset_log "set $id: retrying$( printf ' %s' $hosts)"
            SALA_PSET_WORKER="$id" "$SALA_BIN" provision --no-recycle --not-master $hosts >/dev/null 2>&1 </dev/null
        done
        [ -n "$(_pset_failed_hosts "$id")" ] && _set_locked _pset_expire "$id" worker-end
        pset_log "set $id: retry worker done — $(set_val "$id" done)/$(set_val "$id" total) OK, $(_nlines "$(_pset_items "$id")") item(s) open"
        exit 0 ;;
esac
CHECK=0; HOSTS=(); SESSION=0; RECYCLE=1; ONLY=""; QUIET=0
NOTMASTER=""; PSTART=$(date +%s)
while [ $# -gt 0 ]; do case "$1" in --check) CHECK=1 ;; --session) SESSION=1 ;; --no-recycle) RECYCLE=0 ;; --not-master) NOTMASTER=--not-master ;;
    --only) [ -n "${2:-}" ] || die "usage: salamander provision --only STEP[,STEP…] [--check] [HOST…]"; ONLY="$2"; shift ;;
    --quiet) QUIET=1 ;;   # no fleet post: the caller reports (lib/settings-apply.sh); only with --only or --check
    -*) die "usage: salamander provision [--check] [--session] [--no-recycle] [--only STEP[,STEP…]] [--quiet] [HOST…] · --settle <set> <host> <step> ok|gave [\"<note>\"] · --waiting <set> <host> <step> \"<text>\" · --sets" ;; *) HOSTS+=("$1") ;; esac; shift; done
[ "$QUIET" = 1 ] && [ -z "$ONLY" ] && [ "$CHECK" = 0 ] && die "provision --quiet goes with --only or --check: a whole run's leftovers need their provision set and its post"
# an operation (it ends in a recycle): the master's, like recycle/update/retire/revive (--check reads only)
ops_guard provision fleet $NOTMASTER $([ "${CHECK:-0}" = 1 ] && echo --check)
: "${SALA_FLEET_HOSTS:=}"; : "${SALA_PROVISION_TIMEOUT:=1800}"
: "${SALA_PROVISION_STEPS:=}"   # local script piped to each host (bash -s) before the session: its deterministic steps
: "${SALA_PROVISION_STEPS_LINUX:=}"   # local script run on a Linux host after SALA_PROVISION_STEPS: the Linux-only steps
# script_steps <file> <kind: sh> → the step names that script runs: the shell script's own --list (its first column; the
# continuation lines are indented)
script_steps() {
    local f="${1/#\~/$HOME}"; [ -n "$1" ] && [ -r "$f" ] || return 0
    timeout 30 bash "$f" --list 2>/dev/null | awk '/^[^[:space:]#]/ {print $1}'
}
# only_wants <file> <kind> → true without --only, or when the script runs one of the named steps (else it is not sent)
only_wants() { [ -z "$ONLY" ] || script_steps "$1" "$2" | grep -qxF -f <(tr ',' '\n' <<< "$ONLY"); }
if [ -n "$ONLY" ]; then
    [[ "$ONLY" =~ ^[A-Za-z0-9_-]+(,[A-Za-z0-9_-]+)*$ ]] || die "provision --only takes step names joined by commas, e.g. --only settings,deploy"
    [ "$SESSION" = 0 ] || die "provision --only runs script steps; --session is the whole /provision: use one or the other"
    RECYCLE=0
    valid=$( { script_steps "$SALA_PROVISION_STEPS" sh; script_steps "$SALA_PROVISION_STEPS_LINUX" sh; } | sort -u)
    unknown=$(tr ',' '\n' <<< "$ONLY" | grep -vxF -f <(printf '%s\n' "$valid") | tr '\n' ' ')
    [ -z "$unknown" ] || die "provision --only: no step named ${unknown% }. Valid steps: $( [ -n "$valid" ] && echo $valid || echo "none (no step script answers --list: SALA_PROVISION_STEPS, SALA_PROVISION_STEPS_LINUX)")"
    # repo always runs first (Sun Oct 11th 2026): every other step reads the checkout it fast-forwards, and only_wants
    # sends a script only for a step it runs — an --only naming a step of a later stage alone never sent the first stage, so
    # the boxes stayed 119–332 commits behind and the step failed on the stale checkout. The scripts skip names they do not
    # have and run their steps in their own order (repo first). --check too: it shows the lag.
    ASKED="$ONLY"   # the fleet post's header names the steps asked for, as before
    grep -qxF repo <<< "$valid" && ! tr ',' '\n' <<< "$ONLY" | grep -qxF repo && ONLY="repo,$ONLY"
fi
# this box runs its own steps in a whole-fleet run and whenever it is named (`provision <this box> <box1> <box2>`
# skipped this box's steps, because fleet_hosts drops this host); only a whole-fleet run ends in the recycle
LOCALRUN=0; { [ ${#HOSTS[@]} -eq 0 ] || printf '%s\n' "${HOSTS[@]}" | grep -qx -- "$(hostname)"; } && LOCALRUN=1
list=$(fleet_hosts ${HOSTS[@]+"${HOSTS[@]}"}); [ -n "$list" ] || [ "$LOCALRUN" = 1 ] || die "no hosts: pass some, or set SALA_FLEET_HOSTS in $SALA_CONFIG"
mkdir -p "$SALA_LOG_DIR"; REPORT=(); POST=()
# no double quotes inside: the prompt travels in a double-quoted string through the remote shell
# (the owner's name in it is cleaned once in common.sh to letters, digits, space . _ ' -, so it adds no quote, $, backtick or backslash)
PROMPT="/provision  When everything is done, end your reply with exactly one final line of this form, under 100 characters: SALA-SUMMARY: then what applies, joined by a middle dot: OK if nothing changed and nothing needs ${SALA_OWNER_NAME}; N fixed (short what); N needs you (short what); N failed (short what)."
# DETERMINISTIC FIRST (whatever provision can do without a model is done in code): before the headless session, sala itself (1) runs SALA_PROVISION_STEPS on the host —
# lines `STEP|<ok|fixed|failed|manual>|<name>|<detail>` — and (2) updates the CLI (`claude update`, the step a session
# skipped on a Windows box that morning). The session is told what already ran and does only the rest; both halves go into
# the report, so a missed step shows.
run_steps() {  # <host> <kind: posix|local> <log> → STEP lines on stdout; CHECK=1 → the scripts' check-only mode
    local h="$1" kind="$2" hlog="$3" f="${SALA_PROVISION_STEPS/#\~/$HOME}" out ca="" la=()
    # the scripts' flags: --check, --only (single-quoted: one argument through the remote shell)
    [ "$CHECK" = 1 ] && { ca=" --check"; la+=(--check); }
    [ -n "$ONLY" ] && { ca="$ca --only '$ONLY'"; la+=(--only "$ONLY"); }
    ca="${ca:+ --$ca}"
    if [ -n "$SALA_PROVISION_STEPS" ] && [ -r "$f" ] && only_wants "$SALA_PROVISION_STEPS" sh; then
    if [ "$kind" = local ]; then out=$(timeout 600 bash "$f" ${la[@]+"${la[@]}"} 2>&1)
    else out=$(timeout 600 "${SALA_SSH[@]}" "$h" "bash -s$ca" < "$f" 2>&1); fi
    { echo "--- deterministic steps (sala):"; printf '%s\n' "$out"; } >> "$hlog"
    _step_lines "$out"
    fi
    local lf="${SALA_PROVISION_STEPS_LINUX/#\~/$HOME}"
    if [ -n "$SALA_PROVISION_STEPS_LINUX" ] && [ -r "$lf" ] && only_wants "$SALA_PROVISION_STEPS_LINUX" sh; then
        if [ "$kind" = local ]; then out=$(timeout 900 bash "$lf" ${la[@]+"${la[@]}"} 2>&1)
        else out=$(timeout 900 "${SALA_SSH[@]}" "$h" "bash -s$ca" < "$lf" 2>&1); fi
        { echo "--- deterministic Linux steps (sala):"; printf '%s\n' "$out"; } >> "$hlog"
        _step_lines "$out"
    fi
}
# fold_check <apply STEP lines> <check STEP lines> → the apply's lines, where the check after it (--only) still finds a step
# drifting or failing, that step's line replaced by a failed one, so the post and the exit code show it. A step the apply
# itself reported failed keeps its own line: its words say why, and "still off" would only repeat the check's drift
fold_check() {
    awk -F'|' -v OFS='|' 'FILENAME == ARGV[1] { if ($1 == "STEP" && ($2 == "drift" || $2 == "failed")) off[$3] = $4; next }
        $1 == "STEP" { if (!($3 in off)) print; else if ($2 == "failed") { print; delete off[$3] } }
        END { for (n in off) print "STEP", "failed", n, "still off after the apply: " off[n] }' <(printf '%s\n' "$2") <(printf '%s\n' "$1")
}
# a manual step's kind, for the terminal lines: "for a session" | "for <the owner>" ("needs you" went away)
kind_words() { [ "$1" = session ] && echo "for a session" || echo "for ${SALA_OWNER_NAME}"; }
# check_line <STEP lines> → "N ok · drift: a (…), b · left for <the owner>: c · failed: d" (the check-only report for one box)
check_line() {
    local st name detail kind okn=0 dr="" mn="" fl="" line
    while IFS= read -r line; do
        [[ $line == 'STEP|'* ]] || continue
        _pstep_row_r _psr "$line"; IFS=$'\t' read -r st name detail kind <<< "$_psr"
        case "$st" in ok) okn=$((okn+1));; drift) dr="${dr:+$dr, }$name ($detail)";; manual) mn="${mn:+$mn · }left $(kind_words "$kind"): $name ($detail)";; failed) fl="${fl:+$fl, }$name ($detail)";; esac
    done <<< "$1"
    printf '%s ok%s%s%s' "$okn" "${dr:+ · drift: $dr}" "${mn:+ · $mn}" "${fl:+ · failed: $fl}"
}
# steps_det <STEP lines> → prints "<mark>\t<det>" (❌ a failure, ⚠️ something left, ✅ otherwise)
steps_det() {
    local st name detail kind okn=0 det="" mark="✅" line
    while IFS= read -r line; do
        [[ $line == 'STEP|'* ]] || continue
        _pstep_row_r _psr "$line"; IFS=$'\t' read -r st name detail kind <<< "$_psr"
        case "$st" in ok) okn=$((okn+1));; fixed) det="${det:+$det · }$name: $detail";;
                      failed) mark="❌"; det="${det:+$det · }❌ $name: $detail";;
                      manual) [ "$mark" = "✅" ] && mark="⚠️"; det="${det:+$det · }left $(kind_words "$kind"): $name ($detail)";; esac
    done <<< "$1"
    printf '%s\t%s' "$mark" "${det:+$det · }$okn steps ok"
}
# fleet_post <result dir> <host…> → the Slack post (phone-width): a tally header, hosts with the same result and the
# same changes grouped on one line, each change in plain words with counts (never raw keys, never cut), failures and
# needs-you first, and where the per-host detail is (the raw one-line-per-host post
# was hardly legible).
fleet_post() {
    local d="$1"; shift
    SALA_STEP_WORDS_MINE="$SALA_STEP_WORDS_MINE" SALA_PROVISION_ONLY="${ASKED:-$ONLY}" python3 - "$d" "$SALA_LOG_DIR" "$SALA_STEP_WORDS" "$@" <<'PYPOST'
import os, re, sys
d, logdir, words, hosts = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
OWNER = os.environ.get("SALA_OWNER_NAME") or "the owner"   # common.sh exports it
only = os.environ.get("SALA_PROVISION_ONLY", "")   # --only: the header names the steps, so a partial run never reads as a whole one
FRIENDLY = {}   # lib/step-words.tsv, then the box's own rows (SALA_STEP_WORDS_MINE): one table for this post and the set posts (common.sh step_word)
for wf in (words, os.environ.get("SALA_STEP_WORDS_MINE", "")):
    try: lines = open(wf, encoding="utf-8").readlines() if wf else []
    except OSError: lines = []
    for l in lines:
        if l.strip() and not l.startswith("#") and "\t" in l: k, v = l.rstrip("\n").split("\t", 1); FRIENDLY[k] = v
def items(detail):  # "a, b, c" or "x: a b c" → count of entries
    body = detail.split(":", 1)[1] if ":" in detail.split(",")[0] and detail.split(":", 1)[0].count(" ") < 2 else detail
    return [x for x in re.split(r"[,;]\s*|\s+(?=skill:|orphan:)", body.strip()) if x.strip()]
def fixed_line(name, detail):
    if name == "repo":
        m = re.search(r"→\s*(\S+)", detail); return f"repo updated to {m.group(1)}" if m else "repo updated"
    if name == "cli":
        m = re.search(r"→\s*(\S+)", detail); return f"Claude CLI updated to {m.group(1)}" if m else "Claude CLI updated"
    if name == "settings":
        es = [x for x in items(detail) if not x.startswith("(")]
        removed = sum(1 for x in es if "removed" in x or "minus" in x)
        if es and removed == len(es): return f"settings: removed {len(es)} retired entr{'y' if len(es) == 1 else 'ies'}"
        return f"settings: {len(es)} entr{'y' if len(es) == 1 else 'ies'} merged (backup kept)"
    if name == "deploy":
        es = [x.strip() for x in items(detail.split("(")[0]) if x.strip()]
        sk = [x.split(":", 1)[1] for x in es if x.startswith("skill:")]; gone = [x for x in es if x.startswith("orphan:")]; sc = [x for x in es if ":" not in x]
        parts = []
        if sk: parts.append(("skill " + sk[0] if len(sk) == 1 else "skills " + " and ".join(sk)) if len(sk) <= 2 else f"{len(sk)} skills")
        if sc: parts.append(sc[0] if len(sc) == 1 else f"{len(sc)} scripts")
        if gone: parts.append(f"{len(gone)} retired skill{'s' if len(gone) != 1 else ''} removed")
        return "redeployed " + ", ".join(parts) if parts else "scripts and skills redeployed"
    return f"{FRIENDLY.get(name, name)} fixed"
rows = []
for h in hosts:
    mark = open(os.path.join(d, h + ".mark")).read().strip() if os.path.exists(os.path.join(d, h + ".mark")) else "❌"
    steps = [l.split("|", 3) for l in open(os.path.join(d, h + ".steps"), encoding="utf-8").read().splitlines() if l.startswith("STEP|")] if os.path.exists(os.path.join(d, h + ".steps")) else []
    sess = open(os.path.join(d, h + ".sess")).read().strip() if os.path.exists(os.path.join(d, h + ".sess")) else None
    first, rest, okn = [], [], 0
    for _, st, name, detail in [s + [""] * (4 - len(s)) for s in steps]:
        kind = "session" if detail.endswith("|session") else "owner"   # the 5th field, split off
        detail = re.sub(r"\|(session|owner)$", "", detail)
        if st == "failed": first.append(f"failed — {FRIENDLY.get(name, name)}: {detail}")
        elif st == "manual": first.append(f"left for {'a session' if kind == 'session' else OWNER} — {FRIENDLY.get(name, name)}: {detail}")
        elif st == "fixed": rest.append(fixed_line(name, detail))
        if st in ("ok", "fixed"): okn += 1
    rows.append((mark, (sess,), tuple(first + rest), h, okn))
groups = {}
for mark, sk, bullets, h, okn in rows: groups.setdefault((mark, sk, bullets), []).append((h, okn))
order = {"❌": 0, "⚠️": 1, "✅": 2, "⏭️": 3}
ok = sum(1 for r in rows if r[0] == "✅"); on = sum(1 for r in rows if r[0] != "⏭️"); off = len(rows) - on
out = [f"*fleet provision*{' (only ' + only.replace(',', ', ') + ')' if only else ''} · {ok}/{on} OK" + (f" · {off} offline" if off else ""), "─" * 14]
for (mark, (sess,), bullets), hs in sorted(groups.items(), key=lambda kv: (order.get(kv[0][0], 9), kv[1][0][0])):
    ns = sorted({n for _, n in hs}); cnt = f"{ns[0]}" if len(ns) == 1 else f"{ns[0]}–{ns[-1]}"
    head = "offline, skipped" if mark == "⏭️" else f"{cnt} steps OK" + (f", session {sess}" if sess else "")
    out.append(f"{mark} {' · '.join(h for h, _ in hs)}: {head}")
    out += [f"    • {b}" for b in bullets]
out.append(f"Details: {logdir.replace(os.path.expanduser('~'), '~')}/salamander-provision-<host>.log")
print("\n".join(out))
PYPOST
}
summary_of() { tr -d '\r' < "$1" | sed -n "/^=== $2/,\$p" | grep -o 'SALA-SUMMARY:.*' | tail -1 | sed 's/^SALA-SUMMARY:[[:space:]]*//; s/[`*]//g' | cut -c1-120; }
# one_host <host> <result file> → writes "<report line>\t<post line>"; hosts run IN PARALLEL (each remote /provision
# runs on its own box and logs to its own file; nothing on this side is shared), the report is assembled after the
# wait, in host order (the hosts used to run one after another for no reason)
one_host() {
    local h="$1" out="$2" kind v line mark hlog stamp sum rc
    kind=$(fleet_shell "$h") || { printf '%s\t%s\n' "$h: offline, skipped" "⏭️ $h: offline, skipped" > "$out"; echo "⏭️" > "$out.mark"; return; }
    if [ "$CHECK" = 1 ]; then
        v=$(timeout 30 "${SALA_SSH[@]}" "$h" '"$(command -v claude || echo ~/.local/bin/claude)" --version' 2>/dev/null | head -1)
        hlog="$SALA_LOG_DIR/salamander-provision-$h.log"; { echo "=== $(date -Is) salamander provision --check $h"; } >> "$hlog"
        local cks; cks=$(run_steps "$h" "$kind" "$hlog")
        line="$h: online ($kind), claude ${v:-unknown} — $(check_line "$cks")"; printf '%s\t%s\n' "$line" "$line" > "$out"
        _step_lines "$cks" > "$out.steps"; return   # the check's STEP lines too, for a caller that reads the result dir (SALA_PROVISION_RESULT_DIR)
    fi
    hlog="$SALA_LOG_DIR/salamander-provision-$h.log"
    echo "  $h: provisioning ($kind) … (log: $hlog)"
    stamp="$(date -Is)"; { echo "=== $stamp salamander provision $h"; } >> "$hlog"
    local steps cli="" ck cb ca cerr det="" bad=0 fixedn=0 okn=0 extra="" cks=""
    steps=$(run_steps "$h" "$kind" "$hlog")
    if [ -z "$ONLY" ]; then   # --only runs the named script steps and nothing else: no CLI update
        IFS='|' read -r ck cb ca cerr <<< "$(remote_update "$h" update)"
        if [ -n "$cerr" ]; then cli="STEP|failed|cli|$cerr"; elif [ "$cb" != "$ca" ]; then cli="STEP|fixed|cli|$cb → $ca"; else cli="STEP|ok|cli|$ca"; fi
        echo "--- $cli" >> "$hlog"
    fi
    steps=$(_step_lines "$steps"$'\n'"$cli")
    if [ -n "$ONLY" ]; then   # then the check of the same steps
        echo "--- check after the apply (sala):" >> "$hlog"; cks=$(_step_lines "$(CHECK=1 run_steps "$h" "$kind" "$hlog")")
        steps=$(fold_check "$steps" "$cks")
    fi
    local smark; IFS=$'\t' read -r smark det <<< "$(steps_det "$steps")"; [ "$smark" = "❌" ] && bad=1
    if [ "$SESSION" = 0 ]; then
        line="$h: provisioned — sala: $det$( [ -n "$ONLY" ] && echo " · check after: $(check_line "$cks")")"; mark="$smark"
    else
    extra="Already done by sala before you, deterministically (do not repeat these; skip their spec items and report only the rest): $(printf '%s\n' "$steps" | cut -d'|' -f2-4 | tr '\n' ';' | tr -d '$`"')"
    if timeout "$SALA_PROVISION_TIMEOUT" "${SALA_SSH[@]}" "$h" "claude --dangerously-skip-permissions -p \"$PROMPT $extra\"" >> "$hlog" 2>&1; then
        sum=$(summary_of "$hlog" "$stamp")
        line="$h: provisioned — sala: $det | session: ${sum:-no summary line, see $hlog}"
        case "$sum" in *[1-9]*" failed"*) mark="❌";; "") mark="❔";; *) mark="✅";; esac
    else
        rc=$?; sum=$(summary_of "$hlog" "$stamp")
        [ "$rc" = 124 ] && line="$h: FAILED — sala: $det | session timed out after ${SALA_PROVISION_TIMEOUT}s" || line="$h: FAILED (exit $rc) — sala: $det | session: ${sum:-see $hlog}"
        mark="❌"
    fi
    fi
    [ "$bad" = 1 ] && mark="❌"
    echo "  $line"
    printf '%s\t%s\n' "$line" "$mark ${line/: provisioned — /: }" > "$out"
    printf '%s\n' "$steps" > "$out.steps"; echo "$mark" > "$out.mark"
    [ "$SESSION" = 1 ] && echo "${sum:-no summary}" > "$out.sess"
    return 0
}
# the result dir: each box's "<report>\t<post>" line, its STEP lines (<host>.steps, the check's too) and its mark (<host>.mark);
# a caller that wants them names the dir in SALA_PROVISION_RESULT_DIR (lib/settings-apply.sh) and it is left in place
RKEEP=0; rdir="${SALA_PROVISION_RESULT_DIR:-}"; if [ -n "$rdir" ]; then mkdir -p "$rdir"; RKEEP=1; else rdir=$(mktemp -d "${TMPDIR:-/tmp}/sala-provision.XXXXXX") && trap 'rm -rf "${rdir:?}"' EXIT; fi   # the trap removes it on any exit, a stop (SIGTERM from a timeout or a cancelled CI job) included: a bare mktemp -d left `tmp.XXXXXXXXXX` behind
if [ "$CHECK" = 1 ] && [ "$LOCALRUN" = 1 ]; then   # the check covers this box too, run locally (sala runs every box)
    me=$(hostname); hlog="$SALA_LOG_DIR/salamander-provision-$me.log"; { echo "=== $(date -Is) salamander provision --check $me (local)"; } >> "$hlog"
    lcks=$(run_steps "$me" local "$hlog")
    echo "  $me: this box (local), claude $(claude --version 2>/dev/null | head -1) — $(check_line "$lcks")"
    _step_lines "$lcks" > "$rdir/$me.steps"
fi
for h in $list; do one_host "$h" "$rdir/$h" & done; wait
for h in $list; do
    IFS=$'\t' read -r line post < "$rdir/$h" 2>/dev/null || { line="$h: FAILED — no result"; post="❌ $line"; }
    REPORT+=("$line"); POST+=("$post")
    [ "$CHECK" = 1 ] || case "$line" in *offline*) echo "  $line";; esac
    [ "$CHECK" = 1 ] && echo "  $line"
done
allhosts="$list"
if [ "$CHECK" = 0 ] && [ "$LOCALRUN" = 1 ]; then   # this box last: its repo fast-forward must not race the copies piped to the others
    me=$(hostname); hlog="$SALA_LOG_DIR/salamander-provision-$me.log"; { echo "=== $(date -Is) salamander provision $me (local)"; } >> "$hlog"
    lsteps=$(run_steps "$me" local "$hlog"); lcks=""
    if [ -n "$ONLY" ]; then echo "--- check after the apply (sala):" >> "$hlog"; lcks=$(_step_lines "$(CHECK=1 run_steps "$me" local "$hlog")"); lsteps=$(fold_check "$lsteps" "$lcks"); fi
    IFS=$'\t' read -r mark det <<< "$(steps_det "$lsteps")"
    line="$me: provisioned — sala: $det$( [ -n "$ONLY" ] && echo " · check after: $(check_line "$lcks")")$( [ ${#HOSTS[@]} -eq 0 ] && [ "$RECYCLE" = 1 ] && echo "; CLI update + recycle next")"; echo "  $line"
    REPORT+=("$line"); POST+=("$mark ${line/: provisioned — /: }")
    _step_lines "$lsteps" > "$rdir/$me.steps"; echo "$mark" > "$rdir/$me.mark"; allhosts="$allhosts $me"
fi
# pset_run <result dir> <host…> — the run's Slack report: a box outstanding in an open provision set settles into that set
# (its pass post, if anything changed for it); the other boxes, all OK → the single fleet post as before, else a new set
# and its first post. Then the follow-up: the master told about session/owner items, a retry worker for failed ones.
pset_run() {
    local d="$1"; shift; local h s fresh=() routed=() hs anyleft=0
    for h in "$@"; do if [ -n "$(pset_open_for "$h")" ]; then routed+=("$h"); else fresh+=("$h"); fi; done
    for s in $(for h in ${routed[@]+"${routed[@]}"}; do pset_open_for "$h"; done | sort -u); do
        hs=(); for h in "${routed[@]}"; do pset_open_for "$h" | grep -qxF "$s" && hs+=("$h"); done
        _set_locked _pset_apply "$s" "$d" "${hs[@]}"; pset_followup "$s"
    done
    [ ${#fresh[@]} -gt 0 ] || return 0
    for h in "${fresh[@]}"; do
        if [ "$(cat "$d/$h.mark" 2>/dev/null)" = "⏭️" ] || [ ! -f "$d/$h.steps" ] || grep -qE '^STEP\|(failed|manual)\|' "$d/$h.steps"; then anyleft=1; fi
    done
    if [ "$anyleft" = 0 ]; then sala_notify_raw "$(fleet_post "$d" "${fresh[@]}")"; return 0; fi
    pset_create "$PSTART-$$" "$d" "${fresh[@]}"; pset_followup "$PSTART-$$"
}
if [ "$CHECK" = 0 ]; then
    # --only: the single fleet post, never a set (a set's retry worker re-runs a whole provision of its boxes); --quiet: no post
    if [ "$QUIET" = 1 ]; then :; elif [ "$SESSION" = 0 ] && [ -z "$ONLY" ]; then pset_run "$rdir" $allhosts; else sala_notify_raw "$(fleet_post "$rdir" $allhosts)"; fi
    # a remote /provision updates that box's CLI as one of its steps → the version tracker is stale now (not after --only)
    [ "$RKEEP" = 1 ] || rm -rf "${rdir:?}"
    [ -z "$ONLY" ] && printf '%s\n' "${REPORT[@]}" | grep -q 'provisioned' && post_update_hook "provision: $(printf '%s; ' "${REPORT[@]}")" $(printf '%s\n' "${REPORT[@]}" | grep 'provisioned' | cut -d: -f1)
fi
[ "$RKEEP" = 1 ] || { [ -d "${rdir:-}" ] && rm -rf "${rdir:?}"; }
rc=0; { printf '%s\n' "${REPORT[@]}" | grep -q 'FAILED' || printf '%s\n' "${POST[@]}" | grep -q '^❌'; } && rc=1
# the last act of a whole-fleet run: this box's CLI update + the recycle (the master's; standing authorization,
# it relaunches the invoking pane too once idle)
if [ "$CHECK" = 0 ] && [ ${#HOSTS[@]} -eq 0 ] && [ "$RECYCLE" = 1 ]; then
    echo "  → sala recycle --update --force (this box's CLI, then every pane, this one last)"
    SALA_RELAUNCH_KIND=provision "$SALA_BIN" recycle --update --force $NOTMASTER   # KIND: what a waiting pane is told
fi
exit "$rc"
