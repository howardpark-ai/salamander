# lib/settings-apply.sh — every Claude Code settings change the machine spec declares, applied by sala and never by a session. The auto-mode classifier refuses a session that edits the settings it
# runs under, so a settings change that landed in the spec's repo used to wait for the owner's own shell or for the next fleet
# provision. This is a step of `watch` (the 2-min timer; the constraint: a watch step or a unit, not a service of
# its own), not a session: it runs the spec's SETTINGS-CLASS provision steps and nothing else — no CLI update, no full
# provision, no recycle, no pane relaunch (a pane takes the new settings at its next relaunch, as before).
#
# THE USAGE: `settings-apply --help` (sa_usage) prints from its first `salamander settings-apply` line through the `watch --settings` line, so keep it contiguous.
#   salamander settings-apply                   the state: the spec fingerprint, each box's last apply, what is behind
#   salamander settings-apply --check [HOST…]   the check alone, printed: what it would apply where; records and posts nothing
#   salamander settings-apply --run [HOST…]     (the unit sala-auto-settings; by hand in the web UI's Shell) check, then apply where the
#                                               check found drift, then log the changes; no HOST = this box and SALA_FLEET_HOSTS
#   salamander watch --settings                 the tick alone (settings_tick, below)
#
# THE TICK (settings_tick, every watch run; only with SALA_SETTINGS_APPLY=on, the default is off): one hash of the spec's inputs (SALA_SETTINGS_INPUTS under
# SALA_SETTINGS_SPEC_DIR: the spec files and the provision step scripts, read from this box's checkout of the repo that holds the spec, which its
# own sync keeps current; SALA_SETTINGS_SPEC_DIR, SALA_SETTINGS_INPUTS and SALA_SETTINGS_STEPS all empty, the default = no spec, so nothing to apply). Unchanged and nothing behind → nothing else is read. Changed → the boxes behind it (this box and
# every SALA_FLEET_HOSTS host whose last apply is not this fingerprint; a remote one only while the heartbeat store says it
# answers ssh) go to ONE `settings-apply --run <boxes…>` as its own transient unit, sala-auto-settings (wd_launch --fixed:
# systemd refuses a second while one runs, and the runner's flock refuses a second by hand), so a long step never holds the
# tick. A box whose last try failed is tried again after SALA_SETTINGS_RETRY (an hour; one that succeeded on an older spec is due at once); one asleep is tried once the store says it
# answers (and not more than every 5 min); a box still behind SALA_SETTINGS_STALE (a day) after the spec changed is posted
# once per fingerprint.
#
# THE RUN (sa_run): `provision --quiet --check --only <steps> <boxes>` first (lib/provision.sh: repo, then the steps, read-only;
# each box's STEP lines land in SALA_PROVISION_RESULT_DIR), then `provision --quiet --only <steps>` for the boxes whose check
# found a settings step drifting — never for `repo` alone — and provision's own check after the apply (fold_check) says what
# is still off. Before the apply each box's settings.json is backed up beside itself (settings.json.bak-sala-settings-<stamp>;
# the steps keep their own .bak-provision-* too, where they make one) and snapshotted; after it, the two snapshots are diffed
# key by key (a value under a key named like a secret, and anything scrub_text masks, is never written) into the log, and
# a settings.json that no longer parses gets its backup back and the box is a failure. The dry first look: a box the
# service has never checked (no done.<box> in its state: the first run after the install, a host added later) gets the
# check alone, its drift logged as "would apply", and its fingerprint recorded — so switching the service on changes
# nothing by itself; that box is applied from the next spec change on. Which steps are settings-class is the list
# SALA_SETTINGS_STEPS (empty by default: no step, nothing to apply; config.example shows the shape. A step that would loosen a
# permission is not listed here: the allow rules and the like stay the owner's).
#
# THE LOG (SALA_SETTINGS_LOG, ~/.claude/salamander-settings-apply.log): one line per box and run with the fingerprint and the
# spec repo's commit, the step results in the scripts' own words, then one line per settings key changed (path: old → new; a
# list item added or removed as + / -). Slack (sala_post) only when a box FAILED (once per box and fingerprint, 🚨, the
# step's own words) or stays behind past SALA_SETTINGS_STALE (⚠️, once per fingerprint); a quiet apply is log-only.
# State: $SALA_STATE_DIR/settings-apply.state (fp, fp_seen, commit; per box done, tried, offline, fail, posted).
#
# Sourced by bin/salamander (sa_main) and by lib/watch.sh (settings_tick).

: "${SALA_SETTINGS_APPLY:=off}"   # default off: the tick applies nothing until the config says on
: "${SALA_SETTINGS_STEPS:=}"   # the settings-class steps of the spec's provision scripts (config.example); empty (the default) = none: the tick and the run apply nothing
: "${SALA_SETTINGS_SPEC_DIR:=}"   # the spec checkout (config.example); empty (the default) = no spec: the tick and the run find no input and apply nothing
: "${SALA_SETTINGS_INPUTS:=}"   # the fingerprint's files, relative to SALA_SETTINGS_SPEC_DIR (config.example); empty (the default) = no input: the tick and the run find nothing to apply
: "${SALA_SETTINGS_RETRY:=3600}"
: "${SALA_SETTINGS_STALE:=86400}"
: "${SALA_SETTINGS_LOG:=$SALA_LOG_DIR/salamander-settings-apply.log}"
: "${SALA_SETTINGS_LOCK_WAIT:=30}"   # a run waits this long for the tick that launched it to let go of the state lock (tests shorten it)
SA_STATE="$SALA_STATE_DIR/settings-apply.state"; SA_LOCK="$SALA_STATE_DIR/settings-apply.lock"; SA_UNIT=sala-auto-settings

sa_log() {  # (no dirname, mkdir and date process on every line)
    local _t _d=${SALA_SETTINGS_LOG%/*}; [ "$_d" != "$SALA_SETTINGS_LOG" ] || _d=.
    [ -d "$_d" ] || mkdir -p "$_d"
    if [ -z "$SALA_TZ" ]; then _iso_now_r _t; elif [ "$_WHEN_TZ" = 1 ]; then _iso_tz_r _t "$SALA_TZ"; else _t=$(cs_date -Is); fi
    echo "[$_t] $*" >> "$SALA_SETTINGS_LOG"
}
sa_get() { _kv_first "$SA_STATE" "$1"; }
sa_set() { [ -d "$SALA_STATE_DIR" ] || mkdir -p "$SALA_STATE_DIR"; _kv_set "$SA_STATE" "$1" "$2"; }   # (the shell's own rewrite, none when the value stands)
sa_del() { [ -f "$SA_STATE" ] || return 0; _kv_has "$SA_STATE" "$1" || return 0; _kv_without "$SA_STATE" "$1" > "$SA_STATE.tmp.$$" 2>/dev/null; mv -f "$SA_STATE.tmp.$$" "$SA_STATE"; }
sa_on() { case "${SALA_SETTINGS_APPLY,,}" in 1|on|yes|true) return 0;; esac; return 1; }   # only an explicit on; unset or anything else is off
sa_spec_dir() { echo "${SALA_SETTINGS_SPEC_DIR/#\~/$HOME}"; }
sa_where() { [ -n "$SALA_SETTINGS_SPEC_DIR" ] && sa_spec_dir || echo "(no spec: SALA_SETTINGS_SPEC_DIR is not set)"; }
sa_repo() {  # the name the log and the posts give the spec's repo: its checkout's folder name ("spec" when it is no git checkout)
    local t=""; [ -n "$SALA_SETTINGS_SPEC_DIR" ] && command -v git >/dev/null 2>&1 && t=$(git -C "$(sa_spec_dir)" rev-parse --show-toplevel 2>/dev/null)
    if [ -n "$t" ]; then echo "${t##*/}"; else echo spec; fi
}
sa_inputs() {  # the fingerprint's inputs that exist, one absolute path per line
    local d f; d=${SALA_SETTINGS_SPEC_DIR/#\~/$HOME}
    for f in $SALA_SETTINGS_INPUTS; do case "$f" in /*) ;; *) [ -n "$d" ] || continue; f="$d/$f";; esac; [ -r "$f" ] && echo "$f"; done
}
sa_fingerprint() {  # → 12 hex characters over the inputs' names and bytes; 1 when there is no input at all
    local fs f d h; fs=$(sa_inputs); [ -n "$fs" ] || return 1; d=${SALA_SETTINGS_SPEC_DIR/#\~/$HOME}
    h=$({ for f in $fs; do printf '%s\n' "${f#"$d"/}"; cat "$f"; done; } | sha256sum); printf '%s\n' "${h:0:12}"
}
sa_commit() {  # the checkout's commit the inputs come from (read-only; "-" when it is no git checkout)
    local c
    [ -n "$SALA_SETTINGS_SPEC_DIR" ] && command -v git >/dev/null 2>&1 && c=$(git -C "${SALA_SETTINGS_SPEC_DIR/#\~/$HOME}" rev-parse --short HEAD 2>/dev/null) && [ -n "$c" ] && echo "$c" || echo -
}
sa_targets() { local _h _o=""; for _h in $(fleet_hosts); do _o+="$_h "; done; echo "$_SALA_HN $_o"; }   # this box first, then the fleet
sa_awake() {  # <host> → 0 unless the heartbeat store (box a's fleet_ssh) says it does not answer ssh right now
    local sd="${SALA_HEARTBEAT_STATE_DIR:-}"; sd="${sd/#\~/$HOME}"; [ -n "$sd" ] && [ -f "$sd/a/machine.json" ] || return 0
    python3 - "$sd/a/machine.json" "$1" <<'PY'
import json, sys
try: st = (json.load(open(sys.argv[1])).get("fleet_ssh") or {}).get(sys.argv[2])
except Exception: sys.exit(0)
sys.exit(0 if st is None or st.get("ok") else 1)
PY
}
sa_steps_only() { printf '%s' "$SALA_SETTINGS_STEPS" | tr -s ' \n' ',,' | sed 's/^,//; s/,$//'; }   # the --only list
sa_parses() { python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$1" 2>/dev/null; }

# ── the tick (lib/watch.sh) ──────────────────────────────────────────────────
sa_due() {  # <fp> → the boxes behind it that are due now
    local fp="$1" t me now due="" last; me=$_SALA_HN; _now_r now
    for t in $(sa_targets); do
        [ "$(sa_get "done.$t")" = "$fp" ] && continue
        if [ -n "$(sa_get "fail.$t")" ]; then   # a box whose last try failed (set by every failure kind, cleared by a success): once an hour
            last=$(sa_get "tried.$t"); [ $(( now - ${last:-0} )) -ge "$SALA_SETTINGS_RETRY" ] || continue
        fi                                      # a box whose last run succeeded on an older spec is due at once
        if [ "$t" != "$me" ]; then
            sa_awake "$t" || continue                                                                # asleep: once the store says it answers
            last=$(sa_get "offline.$t"); [ $(( now - ${last:-0} )) -ge 300 ] || continue             # … and not more than every 5 min
        fi
        due="$due $t"
    done
    echo "${due# }"
}
sa_stale_check() {  # <fp> — a box still behind a day after the spec changed: one post per fingerprint
    local fp="$1" seen now t why off b=()
    seen=$(sa_get fp_seen); now=$(date +%s)
    [ -n "$seen" ] && [ $(( now - seen )) -ge "$SALA_SETTINGS_STALE" ] || return 0
    [ "$(sa_get stale_posted)" = "$fp" ] && return 0
    for t in $(sa_targets); do
        [ "$(sa_get "done.$t")" = "$fp" ] && continue
        why=$(sa_get "fail.$t"); off=$(sa_get "offline.$t")
        if [ -n "$why" ]; then b+=("$t: $why")
        elif [ -n "$off" ] && [ "$off" -ge "$seen" ] 2>/dev/null; then b+=("$t: has not answered ssh since the spec changed; applied once it answers")
        else b+=("$t: not applied yet"); fi
    done
    [ ${#b[@]} -gt 0 ] || return 0
    sa_set stale_posted "$fp"; sa_log "stale: $(dur_words "$SALA_SETTINGS_STALE") after spec $fp changed, still behind: $(printf '%s; ' "${b[@]}")"
    sala_post "⚠️ *A settings change is not on every box after $(dur_words "$SALA_SETTINGS_STALE")*" "the spec changed $(local_human "$seen") (spec $fp, $(sa_repo) $(sa_get commit))" "${b[@]}" "Details: $SALA_SETTINGS_LOG"
}
sa_tick_locked() {  # <fp> — under the state lock: the fingerprint's change, the stale post, what is due; prints the boxes to launch for
    local fp="$1"
    ( flock -n 7 || exit 0   # a run holds it (sa_run, for its whole run): its own lines say what it does; the next tick looks again
      local old due
      [ -n "$fp" ] || { [ "$(sa_get said)" = noinputs ] || { sa_set said noinputs; sa_log "tick: none of the spec's inputs is readable under $(sa_where) — nothing to apply (SALA_SETTINGS_SPEC_DIR, SALA_SETTINGS_INPUTS)"; }; exit 0; }
      [ -n "$(sa_steps_only)" ] || { [ "$(sa_get said)" = nosteps ] || { sa_set said nosteps; sa_log "tick: SALA_SETTINGS_STEPS is empty — no step to apply (config.example)"; }; exit 0; }
      old=$(sa_get fp)
      if [ "$old" != "$fp" ]; then
          sa_set fp "$fp"; sa_set fp_seen "$(date +%s)"; sa_set commit "$(sa_commit)"; sa_del said
          sa_log "tick: spec $fp ($(sa_repo) $(sa_get commit))${old:+, changed from $old}: boxes behind it are applied when due"
      fi
      sa_stale_check "$fp"
      due=$(sa_due "$fp"); [ -n "$due" ] || exit 0
      if systemctl --user is-active --quiet "$SA_UNIT" 2>/dev/null; then
          [ "$(sa_get said)" = "running $due" ] || { sa_set said "running $due"; sa_log "tick: $due due, but $SA_UNIT from an earlier run still runs — the next tick looks again"; }
          exit 0
      fi
      sa_del said; echo "$due"
    ) 7>>"$SA_LOCK"
}
settings_tick() {
    sa_on || return 0
    local fp due; fp=$(sa_fingerprint) || fp=""
    mkdir -p "$SALA_STATE_DIR"
    due=$(sa_tick_locked "$fp"); [ -n "$due" ] || return 0
    # the launch is outside the lock: the run takes it at once (sa_run waits SALA_SETTINGS_LOCK_WAIT for it)
    sa_log "tick: launching \`settings-apply --run $due\` (unit $SA_UNIT)"
    command -v wlog >/dev/null 2>&1 && wlog "settings: spec $fp — launching \`settings-apply --run $due\` (unit $SA_UNIT)"
    wd_launch --fixed settings "$SALA_SETTINGS_LOG" settings-apply --run $due \
        || { sa_log "tick: systemd-run refused to launch $SA_UNIT for $due"; sala_post "🚨 *Settings apply could not start*" "a settings change (spec $fp) is due on $due, but systemd-run refused to launch it" "Details: $SALA_SETTINGS_LOG"; }
    return 0
}

# ── the run (the unit, or by hand) ──────────────────────────────────────────
sa_provision() {  # <check|apply> <result dir> <box…> → provision's exit code; its lines in <dir>/provision.out, each box's STEP lines in <dir>/<box>.steps
    local mode="$1" d="$2"; shift 2; local ca=()
    [ "$mode" = check ] && ca=(--check)
    SALA_PROVISION_RESULT_DIR="$d" "$SALA_BIN" provision --quiet --no-recycle ${ca[@]+"${ca[@]}"} --only "$(sa_steps_only)" "$@" > "$d/provision.out" 2>&1 7>&- 9>&-
}
sa_classify() {  # <result dir> <box> → "<verdict>\t<n ok>\t<the steps in their own words>"; verdict: offline · none · failed · manual · drift · fixed · ok
    local f="$1/$2.steps" m="" line st name detail kind okn=0 dr="" fl="" mn="" fx="" steps=()
    # the mark and the STEP lines read by the shell (a cat and two greps per box)
    { IFS= read -r -d '' m < "$1/$2.mark"; } 2>/dev/null || :; while [[ $m == *$'\n' ]]; do m=${m%$'\n'}; done
    [ "$m" = "⏭️" ] && { printf 'offline\t0\t\n'; return; }
    { while IFS= read -r line || [ -n "$line" ]; do [[ $line == 'STEP|'* ]] && steps+=("$line"); done < "$f"; } 2>/dev/null
    [ ${#steps[@]} -gt 0 ] || { printf 'none\t0\t\n'; return; }   # no file, or no STEP line in it (ssh dropped mid-run)
    for line in "${steps[@]}"; do
        _pstep_row_r _psr "$line"; IFS=$'\t' read -r st name detail kind <<< "$_psr"
        [ "$name" = repo ] && { okn=$((okn+1)); continue; }   # the checkout's fast-forward runs first and is never a settings change
        case "$st" in
            ok) okn=$((okn+1));;
            drift) dr="${dr:+$dr · }$name ($detail)";;
            fixed) fx="${fx:+$fx · }$name: $detail";;
            failed) fl="${fl:+$fl · }$name ($detail)";;
            manual) mn="${mn:+$mn · }$name ($detail)";;
        esac
    done
    if [ -n "$fl" ]; then printf 'failed\t%s\t%s\n' "$okn" "$fl${mn:+ · left for ${SALA_OWNER_NAME}: $mn}"
    elif [ -n "$mn" ]; then printf 'manual\t%s\t%s\n' "$okn" "$mn"
    elif [ -n "$dr" ]; then printf 'drift\t%s\t%s\n' "$okn" "$dr"
    elif [ -n "$fx" ]; then printf 'fixed\t%s\t%s\n' "$okn" "$fx"
    else printf 'ok\t%s\t\n' "$okn"; fi   # the count before the words: an empty last field reads back empty, an empty middle one would not (tab is IFS whitespace)
}
sa_settings_path() { echo "$HOME/.claude/settings.json"; }
sa_snapshot() {  # <box> <file> → 0: that box's settings.json copied into <file> and parsing; 1: copied, does not parse; 2: could not be read
    if [ "$1" = "$_SALA_HN" ]; then cp -f "$(sa_settings_path)" "$2" 2>/dev/null || return 2
    else timeout 30 "${SALA_SSH[@]}" "$1" 'cat ~/.claude/settings.json' 2>/dev/null | tr -d '\r' > "$2"; [ -s "$2" ] || return 2; fi
    sa_parses "$2" || return 1
}
sa_backup() {  # <box> <stamp> → the backup's path on that box (printed), or nothing when it could not be made
    local b="~/.claude/settings.json.bak-sala-settings-$2"
    if [ "$1" = "$_SALA_HN" ]; then cp -p "$(sa_settings_path)" "${b/#\~/$HOME}" 2>/dev/null && echo "${b/#\~/$HOME}"
    else timeout 30 "${SALA_SSH[@]}" "$1" "cp ~/.claude/settings.json $b" >/dev/null 2>&1 && echo "$b"; fi
}
sa_restore() {  # <box> <backup path on that box> → settings.json put back from it
    if [ "$1" = "$_SALA_HN" ]; then cp -f "${2/#\~/$HOME}" "$(sa_settings_path)" 2>/dev/null
    else timeout 30 "${SALA_SSH[@]}" "$1" "cp $2 ~/.claude/settings.json" >/dev/null 2>&1; fi
}
# sa_diff <before> <after> → one line per key changed: "path: old → new", "+ path: item", "- path: item"; a value under a key
# named like a secret is "…", every line goes through scrub, and the list is cut at 60 lines
SA_DIFF_PY='
import json, re, sys
B, A = (json.load(open(p, encoding="utf-8")) for p in sys.argv[1:3])
SECRET = re.compile(r"(?i)key|token|secret|password|passwd|credential|authorization")
def show(v, path):
    if any(SECRET.search(p) for p in path.split(".")): return "…"
    s = json.dumps(v, ensure_ascii=False, sort_keys=True); return s if len(s) <= 160 else s[:157] + "…"
out = []
def walk(x, y, path):
    if isinstance(x, dict) and isinstance(y, dict):
        for k in sorted(set(x) | set(y)):
            p = f"{path}.{k}" if path else k
            if k not in x: out.append(f"+ {p}: {show(y[k], p)}")
            elif k not in y: out.append(f"- {p}: {show(x[k], p)}")
            else: walk(x[k], y[k], p)
    elif isinstance(x, list) and isinstance(y, list):
        d = lambda i: json.dumps(i, sort_keys=True, ensure_ascii=False); xs = [d(i) for i in x]; ys = [d(i) for i in y]
        out.extend(f"- {path}: {show(i, path)}" for i in x if d(i) not in ys)
        out.extend(f"+ {path}: {show(i, path)}" for i in y if d(i) not in xs)
    elif x != y: out.append(f"{path}: {show(x, path)} → {show(y, path)}")
walk(B, A, "")
for l in out[:60]: print(scrub(l))
if len(out) > 60: print(f"… and {len(out) - 60} more")
'
sa_diff() { PYTHONIOENCODING=utf-8 python3 -c "$SALA_SCRUB_PY"$'\n'"$SA_DIFF_PY" "$1" "$2" 2>/dev/null; }
sa_say() { sa_log "$*"; [ "$SA_PRINT" = 1 ] && echo "$*"; return 0; }   # the log, and stdout for a hand run
sa_run() {  # <check|run> [box…]
    local mode="$1"; shift; local targets=() t me fp commit line dl v words okn apply=() stamp bak now fails=() posted srcs
    local rdir; SA_RDIR=""   # the result dir: SA_RDIR for the EXIT trap (a local is gone when the trap runs)
    me=$_SALA_HN; fp=$(sa_fingerprint) || die "none of the spec's inputs is readable under $(sa_where) (SALA_SETTINGS_SPEC_DIR, SALA_SETTINGS_INPUTS)"
    [ -n "$(sa_steps_only)" ] || die "SALA_SETTINGS_STEPS is empty: no settings-class step to run (config.example)"
    commit=$(sa_commit)
    [ $# -gt 0 ] && targets=("$@") || targets=($(sa_targets))
    SA_PRINT=0; [ "$mode" = check ] && SA_PRINT=1; [ -t 1 ] && SA_PRINT=1
    mkdir -p "$SALA_STATE_DIR" "$SALA_LOG_DIR"
    if [ "$mode" = run ]; then   # the state lock, for the whole run (a check writes no state and needs none)
        exec 7>>"$SA_LOCK"
        if ! flock -w "$SALA_SETTINGS_LOCK_WAIT" 7; then sa_say "run: another settings-apply run holds the lock ($SA_LOCK) — this one is not started"; exit 75; fi
    fi
    rdir=$(mktemp -d "${TMPDIR:-/tmp}/sala-settings-apply.XXXXXX"); SA_RDIR="$rdir"; trap '[ -n "${SA_RDIR:-}" ] && rm -rf "${SA_RDIR:?}"' EXIT
    sa_say "run: spec $fp ($(sa_repo) $commit) — checking ${targets[*]} (steps: $SALA_SETTINGS_STEPS)"
    _now_r now
    sa_provision check "$rdir" "${targets[@]}"
    if ! compgen -G "$rdir/*.steps" >/dev/null && ! compgen -G "$rdir/*.mark" >/dev/null; then   # refused before any box (a step name no script lists, no hosts): one line, one post per fingerprint
        line=$(grep -v '^[[:space:]]*$' "$rdir/provision.out" | tail -1 | cut -c1-300)
        sa_say "run: provision --check did not run: ${line:-no output}"
        if [ "$mode" = run ]; then for t in "${targets[@]}"; do sa_set "tried.$t" "$now"; sa_set "fail.$t" "provision did not run: ${line:-no output}"; done
            [ "$(sa_get posted.provision)" = "$fp" ] || { sa_set posted.provision "$fp"; sala_post "🚨 *Settings apply could not run*" "provision --check --only $(sa_steps_only) refused: ${line:-no output}" "spec $fp ($(sa_repo) $commit); tried again every $(dur_words "$SALA_SETTINGS_RETRY") until the spec changes" "Details: $SALA_SETTINGS_LOG"; }
        fi
        return 1
    fi
    for t in "${targets[@]}"; do
        IFS=$'\t' read -r v okn words <<< "$(sa_classify "$rdir" "$t")"
        case "$v" in
            offline) sa_say "$t: offline, not answering ssh — tried again once it answers"; [ "$mode" = run ] && sa_set "offline.$t" "$now"; continue;;
            none) sa_say "$t: no result from provision --check (see $SALA_LOG_DIR/salamander-provision-$t.log)"; [ "$mode" = run ] && { sa_set "tried.$t" "$now"; sa_set "fail.$t" "no result from the check"; }; fails+=("$t: no result from provision's check (see ~/.claude/salamander-provision-$t.log)"); continue;;
        esac
        [ "$mode" = run ] && sa_set "tried.$t" "$now"
        if [ "$mode" = check ]; then
            case "$v" in ok) sa_say "$t: in step with spec $fp ($okn steps ok)";; drift) sa_say "$t: would apply $words";; *) sa_say "$t: $v: $words";; esac; continue
        fi
        if [ -z "$(sa_get "done.$t")" ]; then   # the dry first look (the header): recorded, nothing changed
            case "$v" in
                ok) sa_say "$t: first look at spec $fp: in step ($okn steps ok) — recorded; applied from the next spec change on";;
                drift) sa_say "$t: first look at spec $fp: would apply $words — recorded, nothing changed; applied from the next spec change on";;
                *) sa_say "$t: first look at spec $fp: $v: $words — recorded, nothing changed; applied from the next spec change on";;
            esac
            sa_set "done.$t" "$fp"; sa_del "fail.$t"; sa_del "offline.$t"; continue
        fi
        case "$v" in
            ok) sa_say "$t: in step with spec $fp ($okn steps ok)"; sa_set "done.$t" "$fp"; sa_del "fail.$t"; sa_del "offline.$t";;
            drift) apply+=("$t"); sa_say "$t: drift: $words — applying";;
            failed|manual) sa_say "$t: the check $( [ "$v" = manual ] && echo "left for ${SALA_OWNER_NAME}" || echo failed): $words"; sa_set "fail.$t" "$words"; fails+=("$t: $words");;
            fixed) sa_say "$t: the check changed something it should not have: $words"; sa_set "fail.$t" "the check wrote: $words"; fails+=("$t: the check wrote: $words");;
        esac
    done
    if [ ${#apply[@]} -gt 0 ]; then
        stamp=$(cs_date +%Y%m%d-%H%M%S); rm -f "$rdir"/*.steps "$rdir"/*.mark
        for t in "${apply[@]}"; do
            bak=$(sa_backup "$t" "$stamp"); printf '%s' "$bak" > "$rdir/$t.bak"
            [ -n "$bak" ] && sa_say "$t: settings.json backed up as $bak" || sa_say "$t: no backup of settings.json could be made (the steps keep their own .bak-provision-* where they write)"
            sa_snapshot "$t" "$rdir/$t.before" || rm -f "$rdir/$t.before"
        done
        sa_provision apply "$rdir" "${apply[@]}"
        for t in "${apply[@]}"; do
            IFS=$'\t' read -r v okn words <<< "$(sa_classify "$rdir" "$t")"
            bak=$(cat "$rdir/$t.bak" 2>/dev/null)
            sa_snapshot "$t" "$rdir/$t.after"; srcs=$?
            if [ "$srcs" = 1 ]; then   # that box's settings.json no longer parses: the backup goes back, the box is a failure
                if [ -n "$bak" ] && sa_restore "$t" "$bak"; then v=failed; words="settings.json did not parse after the apply: the backup was put back ($bak)${words:+; the steps said: $words}"
                else v=failed; words="settings.json does not parse after the apply and no backup could be put back${words:+; the steps said: $words}"; fi
            fi
            case "$v" in
                fixed|ok) sa_say "$t: applied spec $fp ($(sa_repo) $commit): ${words:-nothing to change} · $okn steps ok; panes take it at their next relaunch"
                          sa_set "done.$t" "$fp"; sa_del "fail.$t"; sa_del "offline.$t"; sa_del "posted.$t";;
                offline) sa_say "$t: went offline before the apply — tried again once it answers"; sa_set "offline.$t" "$now"; continue;;
                none) words="no result from the apply (see ~/.claude/salamander-provision-$t.log)"; sa_say "$t: $words"; sa_set "fail.$t" "$words"; fails+=("$t: $words");;
                *) sa_say "$t: apply $( [ "$v" = manual ] && echo "left for ${SALA_OWNER_NAME}" || echo failed) (spec $fp): $words"; sa_set "fail.$t" "$words"; fails+=("$t: $words");;
            esac
            if [ "$srcs" = 0 ] && [ -f "$rdir/$t.before" ]; then
                line=$(sa_diff "$rdir/$t.before" "$rdir/$t.after")
                if [ -n "$line" ]; then while IFS= read -r dl; do sa_say "$t: settings.json $dl"; done <<< "$line"
                else case "$v" in fixed|ok) sa_say "$t: settings.json unchanged by the apply (what changed was elsewhere: ~/.claude.json, a lane's config, or the hooks' scripts)";; *) sa_say "$t: settings.json unchanged";; esac; fi
            elif [ "$srcs" != 1 ]; then sa_say "$t: no before/after snapshot of settings.json to compare (the steps' own words above stand)"; fi
        done
    fi
    if [ "$mode" = run ] && [ ${#fails[@]} -gt 0 ]; then
        posted=(); for t in "${targets[@]}"; do [ -n "$(sa_get "fail.$t")" ] && [ "$(sa_get "posted.$t")" != "$fp" ] && { sa_set "posted.$t" "$fp"; posted+=("$t"); }; done
        if [ ${#posted[@]} -gt 0 ]; then
            sala_post "🚨 *Settings apply failed on $(printf '%s, ' "${posted[@]}" | sed 's/, $//')*" "${fails[@]}" "spec $fp ($(sa_repo) $commit); tried again every $(dur_words "$SALA_SETTINGS_RETRY") until it passes or the spec changes" "Details: $SALA_SETTINGS_LOG"
            sa_say "run: posted the failure on ${posted[*]}"
        fi
        return 1
    fi
    return 0
}
sa_status() {
    local fp t d tr off why
    echo "settings apply: $( sa_on && echo on || echo "off (SALA_SETTINGS_APPLY)" ) · steps: ${SALA_SETTINGS_STEPS:-(none: SALA_SETTINGS_STEPS is empty)}"
    echo "spec: $(sa_where) → $(sa_fingerprint 2>/dev/null || echo 'no readable input') ($(sa_repo) $(sa_commit)); last seen by the tick: $(sa_get fp || true) (state $SA_STATE)"
    for t in $(sa_targets); do
        d=$(sa_get "done.$t"); tr=$(sa_get "tried.$t"); off=$(sa_get "offline.$t"); why=$(sa_get "fail.$t")
        printf '  %-12s %s\n' "$t" "$( [ -n "$d" ] && echo "at spec $d" || echo "never checked (the first run is a dry look)" )$( [ -n "$tr" ] && echo " · last tried $(local_human "$tr")" )$( [ -n "$off" ] && echo " · offline at $(local_human "$off")" )${why:+ · failed: $why}"
    done
    systemctl --user is-active --quiet "$SA_UNIT" 2>/dev/null && echo "unit $SA_UNIT: running" || echo "unit $SA_UNIT: not running"
    echo "log: $SALA_SETTINGS_LOG"
}
sa_usage() { awk '/^#   salamander settings-apply /{p=1} p{print} /^#   salamander watch --settings/{exit}' "$SALA_ROOT/lib/settings-apply.sh" | sed 's/^# \{0,1\}//'; }   # by pattern, not a line range
sa_main() {
    local mode=status targets=()
    while [ $# -gt 0 ]; do case "$1" in
        --run) mode=run ;; --check) mode=check ;; --status) mode=status ;;
        -h|--help) sa_usage; return 0 ;;
        -*) sa_usage >&2; return 2 ;;
        *) targets+=("$1") ;;
    esac; shift; done
    case "$mode" in status) sa_status ;; *) sa_run "$mode" ${targets[@]+"${targets[@]}"} ;; esac
}
