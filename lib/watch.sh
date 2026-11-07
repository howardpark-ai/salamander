# lib/watch.sh — the watchdog, from a timer: every mapped pane's claude kept alive (bare_tick, below), and, when one is
# configured, ONE designated session (the master) kept alive and bridged.
#
# The master is optional (NO MASTER below). When there is one it is the bootstrap anchor: a Claude Code session with
# `sala` on its PATH that the user can always reach from claude.ai. Its identity is the tmux SESSION NAME (SALA_MASTER);
# whatever conversation runs in that pane is the master's — /clear or a resume there is not a fault. Every OTHER mapped pane
# is checked the same way by bare_tick (lib/barepane.sh), whether or not a master exists. Run from a systemd user
# timer every couple of minutes (install.sh prints the unit).
#
#   salamander watch            check, heal the FIRST failure found (one action per run), log, notify
#   salamander watch --check    check only, exit 0 healthy / 1 unhealthy, print the finding
#   salamander watch --limit        only the usage-limit watch (limit_tick, below)
#   salamander watch --signin       only the lane sign-in watch (signin_tick, below)
#   salamander watch --net          only the network-stop wake (net_tick, below)
#   salamander watch --stuck [--dry-run]   only the stuck-question watch (stuck_tick, below); --dry-run prints what it would post
#   salamander watch --settings     only the settings-apply tick (settings_tick, lib/settings-apply.sh)
#   salamander watch --questions    only the parked-question sweep (question_sweep_tick, below)
#   salamander watch --unit-gaps    only the unit-gap pass (unit_gaps_tick, below)
#   salamander watch --sets [--dry-run]   only the flag rule over the open recycle sets (sets_tick, below); --dry-run prints what it would settle and writes nothing
#   salamander watch --continued    only the continued-in follow (cont_tick, lib/continuedin.sh): a pane that moved to a new transcript id keeps its row
#   salamander watch --back-lanes [--dry-run]   only the back agents' lane rule (back_lane_run, below; SALA_BACK_LANE_RULE=on; common.sh "THE BACK AGENTS' LANE RULE"); --dry-run prints what it would queue and write, and queues and writes nothing
#   salamander watch --wrapup [--dry-run]   only the idle wrap-up and clear of background agents (wrapup_tick, lib/wrapup.sh; OFF by default, needs SALA_IDLE_WRAPUP=on); --dry-run prints, per background pane, what it would do or why not, and changes nothing
#
# Checks, in order:              Heal:
#   1. tmux server down          start tmux.service (resurrect restores the layout; its post-restore
#                                hook is `sala revive`) — or a bare server if there is no unit
#   2. master tmux session gone  create it, restore its sidecar row from the state file, `revive --only`
#   3. master pane has no claude `revive --only` (resume its last conversation by UUID; dedupe guard)
#   3c. ONLY WHEN SALA_IDLE_WRAPUP=on (off by default): a BACKGROUND AGENT idle for SALA_IDLE_WRAPUP_MIN minutes (50) (but no longer than SALA_IDLE_WRAPUP_MAX_AGE, 58) is asked to write down what only it knows, and once that turn has
#                                ended its conversation is cleared (/clear typed; the pane map follows the new conversation), so its next
#                                wake starts small instead of reloading ~200k tokens after its prompt cache expired. One log line each,
#                                no post (lib/wrapup.sh). OFF BY DEFAULT (the CLI's own compaction
#                                is the limit): runs only with SALA_IDLE_WRAPUP=on
#   3b. ANY mapped pane at a bare shell with no claude for SALA_BARE_GRACE (180 s, three ticks) → `revive --only` for it, at
#                                most SALA_BARE_MAX (6) panes per tick, one post (lib/barepane.sh; runs with or without a
#                                master, and is the only pane check a no-master box has). A mass SIGKILL of every claude
#                                leaves tmux up and every pane a bare shell: this heals it
#   4. bridge down               screen says "run /remote-control to reconnect" / "Remote Control
#                                disconnected", or no bridge id ≥5 min after launch → type
#                                /remote-control (only when idle, no prompt showing)
#   5. post-boot report          once per boot, after revive's first full sweep has finished (or
#                                SALA_BOOT_GRACE passed without one) and the master is idle (or
#                                SALA_BOOT_DEADLINE passed): push a report into the master's inbox —
#                                boot time, kernel, revive summary, SALA_BOOT_AUDIT; no live master by
#                                the deadline → the notify command gets it instead
# Never: type into a busy pane or a prompt; kill anything; act while a resurrect restore or a
# `salamander revive` is running; act twice on the same failure within SALA_WATCH_COOLDOWN.
# A bridge id that CHANGED since the last healthy run is reported, not fixed (twin hazard).
# NO MASTER (`salamander master --unset`): a master is optional
# the operation queue (lib/op.sh) runs fleet operations. With SALA_MASTER unset, checks 2–4 are off — nothing recreates,
# resumes or bridges a master session, and its cwd.<name> record is gone with the unset — while everything else below runs
# as before: the queue, the automatic update, relaunch and recycle, the deferred panes, the bare-pane heal, the unmapped
# report, the rename sync, the tmux server (tmux.service started when it is down; no bare session is made for a master
# there is none of). Check 5, the post-boot report, goes to Slack as one post per boot, at once (nobody to wait for).
# `--check` then reports "healthy: no master session". A state that still remembers a master with no master_unset record
# is a lost config, as before, and `--check` fails on it.
# State: $SALA_LOG_DIR/salamander-watch.state (uuid, bridge, last action times). Log: salamander-watch.log.
# Notify: SALA_WATCH_NOTIFY_CMD gets the message on stdin (e.g. a Slack webhook helper).
# Besides the master, each run may start one automatic relaunch, cued as soon as it is due: the panes still on an older CLI
# than the installed one (auto_relaunch) or a recycle that board items or `sala recycle --when-idle` asked for
# (auto_recycle); the recycle itself skips a busy pane and its retry worker brings that pane back once it is idle. The CLI
# update itself runs at once too (auto_update).
# A usage-limit stop of the API calls is posted, and so is its end, after which the panes it left idle are told to go on
# (limit_tick; also `watch --limit`). A pane whose last turn ended on a network error (DNS down, API unreachable) is sent one
# message once the API resolves again, once per episode (net_tick; also `watch --net`). A lane signed in to another account than the one configured for it is posted once, and
# so is its return (signin_tick; also `watch --signin`). A pane stopped on a terminal-only question (a permission dialog, a
# menu) is posted once per question, with its sala-web link (stuck_tick; also `watch --stuck`). A Claude Code settings change
# that lands in the machine spec is applied by sala, on this box and the fleet, never by a session (settings_tick,
# lib/settings-apply.sh; also `watch --settings`).

: "${SALA_WATCH_COOLDOWN:=600}"
WLOG="$SALA_LOG_DIR/salamander-watch.log"; WSTATE="$SALA_LOG_DIR/salamander-watch.state"
CHECK_ONLY=0; [ "${1:-}" = --check ] && CHECK_ONLY=1
LIMIT_ONLY=0; [ "${1:-}" = --limit ] && LIMIT_ONLY=1
SIGNIN_ONLY=0; [ "${1:-}" = --signin ] && SIGNIN_ONLY=1
NET_ONLY=0; [ "${1:-}" = --net ] && NET_ONLY=1
OPS_ONLY=0; [ "${1:-}" = --ops ] && OPS_ONLY=1   # `sala watch --ops`: the operation queue alone (lib/op.sh)
SETTINGS_ONLY=0; [ "${1:-}" = --settings ] && SETTINGS_ONLY=1   # `sala watch --settings`: the settings-apply tick alone (lib/settings-apply.sh)
QUESTIONS_ONLY=0; [ "${1:-}" = --questions ] && QUESTIONS_ONLY=1   # `sala watch --questions`: the parked-question sweep alone
UNITGAPS_ONLY=0; [ "${1:-}" = --unit-gaps ] && UNITGAPS_ONLY=1   # `sala watch --unit-gaps`: the unit-gap pass alone
WRAPUP_ONLY=0; [ "${1:-}" = --wrapup ] && WRAPUP_ONLY=1   # `sala watch --wrapup [--dry-run]`: the idle wrap-up and clear of background agents alone (lib/wrapup.sh)
SETS_ONLY=0; [ "${1:-}" = --sets ] && SETS_ONLY=1   # `sala watch --sets [--dry-run]`: the flag rule over the open recycle sets alone (common.sh, set_sync)
BACKLANES_ONLY=0; [ "${1:-}" = --back-lanes ] && BACKLANES_ONLY=1   # `sala watch --back-lanes [--dry-run]`: the back agents' lane rule alone (back_lane_run, below; common.sh)
CONT_ONLY=0; [ "${1:-}" = --continued ] && CONT_ONLY=1   # `sala watch --continued`: the continued-in follow alone (lib/continuedin.sh; lib/follow.py runs it when a registry row's sessionId changes)
. "$SALA_ROOT/lib/op.sh"
. "$SALA_ROOT/lib/settings-apply.sh"
. "$SALA_ROOT/lib/continuedin.sh"
. "$SALA_ROOT/lib/barepane.sh"
. "$SALA_ROOT/lib/wrapup.sh"
[ -d "$SALA_LOG_DIR" ] || mkdir -p "$SALA_LOG_DIR"; [ -e "$WSTATE" ] || >> "$WSTATE"   # (touch and mkdir -p each tick: two processes; nothing reads the state file's mtime)
wlog() { local _wt; _iso_now_r _wt; echo "[$_wt] $*" >> "$WLOG"; }
st_get() { _kv_first "$WSTATE" "$1"; }
# the master's own directory (recorded by `master --set` and refreshed below while its pane lives): a recreated master
# session starts there, so a resume finds its transcript and the role directory's CLAUDE.md loads (a master pane
# spawned with --cwd in a role directory used to come back in $HOME)
master_dir() { local d; d=$(st_get "cwd.$SALA_MASTER"); [ -n "$d" ] && [ -d "$d" ] && echo "$d" || echo "$HOME"; }
st_set() { _kv_set "$WSTATE" "$1" "$2"; }   # per-process tmp: the timer run and a --check may overlap
st_del() { _kv_without "$WSTATE" "$1" > "$WSTATE.tmp.$$" 2>/dev/null; mv -f "$WSTATE.tmp.$$" "$WSTATE"; }
notify() { wlog "NOTIFY $*"; [ -n "${SALA_WATCH_NOTIFY_CMD:-}${SALA_NOTIFY_CMD:-}" ] && sala_post "$@"; return 0; }   # <headline> [bullet…] (sala_post's shape)
report_bullets() { boot_report notify | sed 's/^\[sala boot\] //; s/^  - //; s/^  ⤷ //'; }   # the post-boot report, one bullet per line
# wd_launch [--fixed] <unit tag> <log> <sala args…> [-- <systemd-run options…>]: a run that outlives this oneshot, as its own
# transient unit. KillMode=process: a recycle detaches its driver and exits, and the default control-group kill
# took the driver down with the unit's main process, so panes were left on the old CLI. The unit is sala-auto-<tag>-<epoch>; --fixed makes it plain sala-auto-<tag>, so systemd refuses a second one
# while the first still runs (provision_sets_tick).
wd_launch() {
    local unit_sfx="-$(date +%s)"; [ "$1" = --fixed ] && { unit_sfx=""; shift; }
    local tag="$1" log="$2"; shift 2; local args=() opts=()
    while [ $# -gt 0 ] && [ "$1" != -- ]; do args+=("$1"); shift; done; [ $# -gt 0 ] && { shift; opts=("$@"); }
    systemd-run --user --quiet --collect -p KillMode=process ${opts[@]+"${opts[@]}"} --unit="sala-auto-$tag$unit_sfx" \
        bash -c "exec '$SALA_BIN' ${args[*]} >> '$log' 2>&1"
}
# fleet_awake → "<host>|<claude version>" per remote box the heartbeat store says answers ssh right now (box a's
# fleet_ssh); the version is empty when that box's own record is unreadable. Shared by auto_update and provision_sets_tick.
fleet_awake() {
    SD="${SALA_HEARTBEAT_STATE_DIR/#\~/$HOME}" python3 - <<'PYF' 2>/dev/null
import json, os
sd = os.environ["SD"]
if not sd: raise SystemExit
try: fs = json.load(open(os.path.join(sd, "a", "machine.json"))).get("fleet_ssh", {})
except Exception: fs = {}
for host, st in fs.items():
    if not st.get("ok"): continue
    try: v = json.load(open(os.path.join(sd, st["letter"], "machine.json"))).get("claude", "")
    except Exception: v = ""
    print(f"{host}|{v}")
PYF
}
# The provision state file: per-box "tried" stamps of the provision sets below, under their own flock, so the tick never
# rewrites the watch state behind another run. (The puller catch-up that shared it was removed with the Windows boxes,
# contract version 11.)
APSTATE="$SALA_LOG_DIR/salamander-autoprovision.state"
ap_get() { _kv_first "$APSTATE" "$1"; }
ap_set() { _kv_set "$APSTATE" "$1" "$2"; }
# PROVISION SETS (common.sh "provision sets"), every tick: an open set's give-ups (pset_expire),
# the master told about items it has not heard of yet (pset_tell: a delivery that failed is retried here), and a box a set
# lists as offline that the heartbeat store says answers ssh again → ONE `provision --no-recycle <hosts…>` (its own unit,
# fixed name sala-auto-provision-sets; not while it still runs; a box at most every
# SALA_RETRY_EVERY), which settles those boxes into their set.
provision_sets_tick() {
    [ -d "$SALA_SET_DIR" ] || return 0
    local id h now due="" awake off=""
    for id in $(pset_open); do pset_expire "$id"; pset_tell "$id"; done
    for id in $(pset_open); do off="$off $(set_vals "$id" offline | tr '\n' ' ')"; done
    [ -n "${off// /}" ] || return 0
    awake=" $(fleet_awake | cut -d'|' -f1 | tr '\n' ' ') "; now=$(date +%s)
    ( flock -w 60 8 || exit 0
      for h in $(printf '%s\n' $off | sort -u); do
          case "$awake" in *" $h "*) ;; *) continue;; esac
          [ $(( now - $(ap_get "pset_tried_$h" | grep . || echo 0) )) -ge "$SALA_RETRY_EVERY" ] && due="$due $h"
      done
      [ -n "$due" ] || exit 0
      systemctl --user is-active --quiet sala-auto-provision-sets 2>/dev/null && exit 0
      for h in $due; do ap_set "pset_tried_$h" "$now"; done
      wlog "provision sets: back online:$due — launching \`provision --no-recycle$due\`"
      wd_launch --fixed provision-sets "$SALA_LOG_DIR/salamander-provision.log" provision --no-recycle $due \
          || wlog "provision sets: systemd-run refused to launch the provision of$due"
    ) 8>>"$APSTATE.lock"
}
# USAGE-LIMIT WATCH: when a weekly usage limit stops the API calls, no alert reaches the operator if every alert path goes
# through a Claude session blocked the same way; and panes that ended a turn on the limit error with an incoming message
# unhandled stay idle after the limit lifts, until each is nudged by hand and the failed oneshot units are restarted. This step
# takes no Claude turn and makes no API call: it reads the tails of the transcripts (~/.claude/projects/**/*.jsonl) written
# in the last SALA_LIMIT_LOOKBACK.
# PER PANE, NOT PER BOX: the accounts and lanes on one box stop and come back separately (some panes stay on the error while
# others work), so a whole-box stop is no trigger. Each pane is judged on its own transcript.
# PER LANE, AND THE LIMIT NAMED: a post must tell which lane each pane is on and exactly which limit is hit. A pane relaunched on
# another lane with the same conversation keeps an older error in its tail with no normal record of its own after it, although
# its lane has worked since, so a "since" taken from the tail alone is wrong. Each pane therefore carries the lane it RUNS on
# (common.sh lane_running: /proc, else the recorded lane) and each error the lane it was hit on, every post names the lane and
# the limit, a lane's own successes bound a pane's "since" and lift its panes, and the headless runs (claude -p: no pane) are
# reported by their directory.
#  - THE ERROR RECORDS (Claude Code, pinned here; the fixtures in tests/fixtures are the shapes): an
#    assistant record with isApiErrorMessage true. A USAGE LIMIT: error "rate_limit", apiError "usage_limit_reached"
#    (an older CLI wrote no apiError, only quotaLimits.status "rejected"); which limit is quotaLimits.rateLimitType
#    ("seven_day" the weekly limit, "five_hour" the 5-hour one, "seven_day_<model>" one model's weekly limit; the same
#    under apiErrorParams.rate_limit_info); the reset is quotaLimits.resetsAt (or rate_limit_info.resetsAt), epoch seconds.
#    Whose limit it is comes from the pane's lane: a login lane shows its display name (lane_label; the old words max and
#    team in an older record are read as the lanes' current codes). apiError
#    "model_requires_usage_credits" (one model's credits; another model works) is not a stop. THE API LANE'S OWN KINDS: the
#    WORKSPACE SPENDING LIMIT (the API key's workspace hit its spending limit; fixture tests/fixtures/limit-workspace.jsonl):
#    error "unknown", apiErrorStatus 400, no apiError, no quotaLimits, the text "API Error: 400 You have reached your
#    specified workspace API usage limits. You will regain access on <date> at 00:00 UTC." → "API workspace spending limit",
#    its reset the "regain access on <date> at <HH:MM> UTC" (matched first, by its text). THE CREDIT (fixture
#    tests/fixtures/limit-billing.jsonl): error "billing_error", apiErrorStatus 400, no apiError, no quotaLimits, no
#    errorDetails, the text just "Credit balance is too low" → "API credit ran out" (the error key first, the text "credit
#    balance" as a fallback for an older CLI). One more with no recorded sample (the API's documented error as the
#    CLI would record it, matched loosely): a 429 is error "rate_limit" with no quotaLimits → "API rate limit", transient (a
#    stop only when it persists past SALA_LIMIT_CONFIRM, like any other). Any other API error
#    (server_error, authentication_failed, a parse failure) is neither a stop nor a normal record. A NORMAL record is an
#    assistant record that is no API error and not from the "<synthetic>" model; its message.model says which model
#    answered (a success of that model is what lifts one model's limit).
#  - THE LANE OF AN ERROR COMES FROM THE ERROR, never from the lane running when the watch first sees it: panes relaunched
#    from the api lane onto a login lane can still have a billing_error in their tails; if the watch dropped their api stop while
#    they had no claude process mid-relaunch, it would see the old records on the login lane and post a stop there that is not
#    true. An API kind (rate,
#    credit, workspace) is the api lane's whatever lane runs the pane now: only an API key meets it, a login lane has no
#    credit. A login kind (the weekly and 5-hour limits, usage_limit_reached) is the login lane the pane ran on when ITS
#    process wrote the record (remembered per error, kept for the lookback: seen), else the login lane it runs on; on an
#    api-lane process it is some login lane's ("login", named without a login). An error whose lane is not the lane the
#    pane runs on now is a pane that MOVED (its error is older than its process, or the lane could not be read): never a
#    stop on the lane it runs on, but a lift "moved to the <lane> lane" (told once, in the stopped panes or not). An error
#    older than the pane's process on the same lane is still its stop (a relaunch with the same conversation while the
#    lane is out), lifted at once when the lane has a success since the error. A stopped pane that has no claude process
#    while a relaunch holds the recycle lock keeps its stop (it is coming back); gone otherwise, it drops.
#  - STOPPED: a live pane whose newest assistant record has been a limit error for SALA_LIMIT_CONFIRM seconds, counted from
#    its first error of THIS episode: the first after the newest of its own last normal record, the error's lane's last
#    success before the error (any pane on that lane, the limit's model where it names one; from the tails and from what
#    earlier runs saw, since a busy pane's tail loses its past), and a lift by reset. The panes that become stopped in one
#    run get ONE post (SALA_LIMIT_ALERT): a line per lane, limit and reset — "<lane> lane: <limit> since …, it says
#    it resets …: the panes"; "api lane: out of API credit since …: the panes". A posted pane is remembered, so it is
#    posted once per stop; one stopped later is a later post.
#  - LIFTED, pane by pane, with its reason: a normal record after its error (on the lane it was hit on: "the <limit>
#    reset at …" after the reset, "the <limit> lifted early" before it; on another lane: "moved to the <lane> lane"); still
#    on the error but running on another lane than the error's ("moved", it is told to go on); still on the error while
#    its lane has a success newer than the error ("the <limit> reset at …" once the reset has passed and the success is
#    after it, else "lifted early", as when credits bought lift the stop with the reset time
#    unchanged; for the api lane's kinds, which have no reset to be early to: "API credit was added", "the API rate limit
#    lifted"). A lane's success is a pane's normal record made since its claude process started, never an older one in
#    its tail. The panes lifted in one run get ONE post, its headline naming the lanes they work on
#    now, a line on what had stopped them ("the <limit> had stopped them since …", "API credit had run out for 2
#    of them since …") and a line per reason. EVERY LIMIT'S NAME is one phrase per sentence it appears in (lw_limit,
#    lw_since, lw_had, lw_why), and the pairing of lane and kind is structural there as in the scan: an API kind is always
#    "API …", a login kind on the api lane or with no lane never carries a login.
#  - RESUME (SALA_LIMIT_RESUME): each lifted pane still on its error is told once, through its messaging socket, why calls
#    work again and to handle its last incoming message; one busy then (or while a recycle runs) is told once it is idle,
#    for SALA_LIMIT_RESUME_FOR. When the last stopped pane lifts, each of sala's own oneshot user units (sala-*,
#    salamander-*; never sala-watch itself or a transient sala-auto-* run) that failed at or after the stop's start is reset
#    and started (--no-block), once.
#  - HEADLESS (a recurring `claude -p` timer that hits the weekly limit unseen): a transcript that is
#    no pane's (not now, not at any tick of the lookback), written in the lookback, whose newest assistant record is a
#    limit error made by `claude -p`, is a headless run on the error, judged on its own (its conversation, its error time).
#    ONLY `claude -p` COUNTS: the newest record's top-level "entrypoint" must be "sdk-cli" (headless `claude -p`).
#    "cli" (an interactive session no pane holds, for example one started by hand outside the panes) is skipped and keeps
#    no state. The key sits at the top level of every user, assistant, attachment and system
#    record (not on the bookkeeping ones: mode, last-prompt, file-history-snapshot), and every API error record has it.
#    The only assistant records without it are normal answers from a build that wrote no "version" either, never an error: a
#    record with no entrypoint is skipped too. Agent SDK runs ("sdk-py", "sdk-ts") are not counted either. It is named by
#    WHAT STARTED IT, never by a bare folder: the systemd user unit whose explicit
#    WorkingDirectory is the record's cwd (`show` prints an implicit one as "!/home/alex": no match; nor the home folder
#    itself, which is everyone's), else a oneshot of ours (a name starting with one of SALA_OWN_UNIT_PREFIXES, default sala-,salamander-) whose last run started within a minute
#    of the error or spanned it (a daemon's run spans everything since boot: never), else the one the user journal shows
#    starting or writing within a minute of the error (USER_UNIT, _SYSTEMD_USER_UNIT; at most LW_JOURNAL lookups a tick,
#    the rest wait for the next) — a unit whose implicit working directory is the home folder ranks above one with
#    another explicit one for a run in the home folder, then the closest in time; sala's own ticks (watch, heartbeat)
#    never, they run no claude. Resolved when the run is first seen and remembered (hseen); else plain words
#    with the full folder ("a Claude run from the home folder (/home/alex)"). The unit's Description names it when short,
#    else its name. A run that later succeeded is dropped: a later normal record from the same starter (a transcript resolved to
#    the same unit, or the same folder when neither resolves), or the unit's own later successful run (Result success
#    with ExecMainExitTimestamp or ActiveEnterTimestamp after the error: a daily oneshot that failed on
#    the limit and was re-run leaves no transcript). The runs of one starter still on the error are
#    one line, posted once per starter per episode (the first run's time, the count), in the stop post or in a post of
#    its own; a success of that starter ends the episode. Nothing is resumed: a unit's next scheduled run tries again,
#    a run no unit started is retried by nobody, and the line says which.
#  - A pane that is retired or gone drops out of the state without a word.
# Both knobs off: nothing is read or kept. State: salamander-limit.json (the scan keeps it: the stopped panes with their
# lane and limit, the lifts by reset, each pane's and lane's last success seen, the headless runs seen with their starter
# and the starters posted, the conversations seen as panes in the lookback), salamander-limit.resume (the panes still to
# be told: conversation|error uuid|until|stop start|why|lane).
: "${SALA_LIMIT_ALERT:=on}"; : "${SALA_LIMIT_RESUME:=on}"; : "${SALA_LIMIT_CONFIRM:=600}"; : "${SALA_LIMIT_LOOKBACK:=259200}"
: "${SALA_LIMIT_RESUME_FOR:=3600}"
LW_STATE="$SALA_LIMIT_STATE"; LW_RESUME="$SALA_LOG_DIR/salamander-limit.resume"   # the state's path is common.sh's: lane_out reads it (the rescue)
lw_when() {  # <epoch> → "Mon Jan 5th 09:30" in SALA_TZ (this machine's local time when unset)
    local w; _when_r w "$1"; printf '%s\n' "$w"
}
lw_panes() {  # "<session>|<claude pid>|<lane it runs on>" for every claude under a tmux pane (one ps pass, unmapped_report's walk)
    # the walk is the shell's own (_claude_panes_r: it was an awk and a process-substitution subshell per tick, and a subshell per pane for the lane)
    local s pid ln t; _panes_get_r t
    while IFS='|' read -r s pid; do
        [ -n "$s" ] || continue
        _lane_running_r ln "$pid" "$s"; echo "$s|$pid|$ln"
    done <<< "$t"
}
# THE LIMITS' NAMES: lw_limit <lane> <limit> (lib/common.sh, beside lane_out — the rescue reads this state too), one
# phrase per sentence a limit appears in; the lane/kind pairing there is the scan's (LW_PY's API_KINDS is the same list)
# lw_since <lane> <limit> <since> → the stop bullet's and the headless line's opening: "<name> weekly limit since Mon Jan 5th
# 09:30", "out of API credit since Tue Jan 6th 10:28", "API rate limit since …"
lw_since() { case "$2" in credit) echo "out of API credit since $(lw_when "$3")";; *) echo "$(lw_limit "$1" "$2") since $(lw_when "$3")";; esac; }
# lw_resets <limit> <reset> → the stop bullet's reset clause: ", it says it resets Wed Jan 7th 14:00"; ", with no reset time
# given" for a kind that has one (a 429 without it); nothing for the credit, which has none
lw_resets() { if [ "$2" -gt 0 ]; then echo ", it says it resets $(lw_when "$2")"; elif [ "$1" != credit ]; then echo ", with no reset time given"; fi; }
# lw_had <lane> <limit> <whom> <since> → the lift post's line on what had stopped them: "the <name> weekly limit had stopped them
# since …", "API credit had run out for 2 of them since …"
lw_had() { case "$2" in credit) echo "API credit had run out for $3 since $(lw_when "$4")";; *) echo "the $(lw_limit "$1" "$2") had stopped $3 since $(lw_when "$4")";; esac; }
# the scan and the state: the panes on stdin; it rewrites LW_STATE and prints what this run does, one line each:
#   stop <session> <lane> <limit> <reset> <since>                      a pane newly stopped (the run's stops are one post)
#   lift <session> <pid> <conversation> <error uuid|-> <lift epoch> <why> <lane now> <lane at the error> <limit> <since> <reset> <0 went on|1 to be told>
#       why: reset (the reset passed, a success after it) · lifted (a success before the reset: its own, or its lane's) ·
#       moved (another lane than the error's)
#   units <stop start>                                                 the last stopped pane lifted
#   cur <conversation> <pid> <session> <error uuid>                    every live pane on the error now (for the resume list)
#   headless <since> <limit> <reset> <runs> <unit|-> <starter…>        a starter whose pane-less runs newly end on the error
IFS= read -r -d '' LW_PY <<'PYL' || :   # (a read, not $(cat <<…): no cat process)
import glob, json, os, re, subprocess, sys, time
from datetime import datetime, timezone
SP, RD, STF = os.environ["SP"], os.environ["RD"], os.environ["STF"]
LB = int(os.environ.get("LB") or 259200); CONFIRM = int(os.environ.get("CONFIRM") or 600)
now = int(time.time()); TAIL = 262144; HTAIL = 16384; cache = {}; HOME = os.path.expanduser("~")
def ep(ts):
    try: return int(datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp())
    except Exception: return 0
REGAIN = re.compile(r"regain access on (\d{4}-\d{2}-\d{2}) at (\d{1,2}):(\d{2}) UTC", re.I)
def regain(text):  # "… You will regain access on 2099-01-01 at 00:00 UTC." → its epoch, 0 when absent
    m = REGAIN.search(text)
    try: return int(datetime.strptime("%s %s:%s" % m.groups(), "%Y-%m-%d %H:%M").replace(tzinfo=timezone.utc).timestamp()) if m else 0
    except Exception: return 0
def kind(o):  # → None | ("ok", 0, "", model) | ("err", reset, limit, "")
    if o.get("type") != "assistant": return None
    msg = o.get("message") or {}
    if o.get("isApiErrorMessage"):
        q = o.get("quotaLimits") or {}; rl = ((o.get("apiErrorParams") or {}).get("rate_limit_info") or {}); ae = o.get("apiError")
        if ae == "usage_limit_reached" or (not ae and q.get("status") == "rejected"):
            try: r = int(q.get("resetsAt") or rl.get("resetsAt") or 0)
            except Exception: r = 0
            return ("err", r, str(q.get("rateLimitType") or rl.get("rateLimitType") or "usage"), "")
        text = " ".join(str(c.get("text", "")) for c in (msg.get("content") or []) if isinstance(c, dict)) + " " + str(o.get("errorDetails") or "")
        if "specified workspace api usage limits" in text.lower(): return ("err", regain(text), "workspace", "")   # (the header)
        if o.get("error") == "billing_error" or "credit balance" in text.lower(): return ("err", 0, "credit", "")   # error "billing_error", "Credit balance is too low" (the header)
        if ae: return None   # model_requires_usage_credits: one model's credits, another model works; any other named kind
        if o.get("error") == "rate_limit": return ("err", 0, "rate", "")       # a 429 with no usage-limit record: the API's rate limit (no real sample yet)
        return None
    if msg.get("model") == "<synthetic>": return None
    return ("ok", 0, "", str(msg.get("model") or "").lower())
ents = {}   # (path, tail) → the entrypoint of each record recs() returns, in its order ("" when the record has none)
def recs(p, tail=TAIL):  # the tail's classified assistant records, oldest first: (epoch, ok|err, reset, limit, uuid, cwd, model)
    if (p, tail) in cache: return cache[(p, tail)]
    out = []; en = []
    try:
        with open(p, "rb") as f:
            f.seek(0, 2); size = f.tell(); f.seek(max(0, size - tail)); data = f.read()
        lines = data.decode("utf-8", "replace").split("\n")
        if size > tail: lines = lines[1:]
    except OSError: lines = []
    for l in lines:
        if '"assistant"' not in l: continue
        try: o = json.loads(l)
        except Exception: continue
        k = kind(o) if isinstance(o, dict) else None
        if k: out.append((ep(o.get("timestamp") or ""), k[0], k[1], k[2], str(o.get("uuid") or ""), str(o.get("cwd") or ""), k[3])); en.append(str(o.get("entrypoint") or ""))
    cache[(p, tail)] = out; ents[(p, tail)] = en; return out
def fam(lim):  # the model a limit names ("seven_day_opus" → "opus"), "" when it covers every model
    for pre in ("seven_day_", "five_hour_"):
        if lim.startswith(pre): return lim[len(pre):].lower()
    return ""
# THE LANE OF AN ERROR COMES FROM THE ERROR (the header): an API kind is the api lane's whatever lane runs
# the pane now; a login kind is the login lane whose process wrote it (seen, remembered per error for the lookback), else
# the login lane the pane runs on; on an api-lane process some login lane's ("login"). lw_limit keeps the same API_KINDS.
API_KINDS = ("rate", "credit", "workspace")
def err_lane(lim, lane, seen_lane):
    if lim in API_KINDS: return "api"
    if seen_lane and seen_lane != "api": return seen_lane
    return lane if lane != "api" else "login"
RELAUNCH = os.environ.get("RELAUNCH") == "1"   # a relaunch holds the recycle lock: a stopped pane with no claude process right now is coming back
try: st = json.load(open(STF))
except Exception: st = {}
panes, done, seen, pok, laneok, headless, pseen, hseen = (st.get(k) or {} for k in ("panes", "done", "seen", "pok", "laneok", "headless", "pseen", "hseen"))
# A LANE RENAMED SINCE THE STATE WAS WRITTEN (awsplatform; max and team, now subscription-1 and subscription-2): the old word in a stored
# row is the same lane, so it is read as the current code (the rows are rewritten in the new code as the watch touches them)
REN = {"awsplatform": "aws-platform", "max": "subscription-1", "team": "subscription-2"}
for _d in (panes, seen):
    for _p in _d.values():
        if isinstance(_p, dict) and _p.get("lane") in REN: _p["lane"] = REN[_p["lane"]]
# a laneok value is the epoch of the lane's newest success, so when the old word's key and the new code's key are both stored (the watch wrote
# the new one after the rename, the old one is a carried row) the LARGER value wins, whichever is read last: the newer success is the truth
_lo = {}
for k, v in laneok.items():
    if "|" in k: k = REN.get(k.split("|", 1)[0], k.split("|", 1)[0]) + "|" + k.split("|", 1)[1]
    try: _lo[k] = max(_lo[k], v) if k in _lo else v
    except TypeError: _lo.setdefault(k, v)
laneok = _lo
# A PANE'S RECORDS FROM BEFORE ITS PROCESS ARE NOT ITS LANE'S: a pane may have normal records from
# turns made on another login; relaunched onto the api lane while out of API credit, those records would be credited to the
# api lane, and the watch would post its panes "lifted early" while they still get "Credit balance too
# low". The tail outlives the process and the lane: only a record at or after the pane's claude process started (/proc
# <pid>/stat field 22 over CLK_TCK, plus btime; else the registry's startedAt; 0, every record, when neither reads) is a
# success of the lane it runs on now. An older one is still the pane's own (pok: it bounds the pane's own episode).
# PSTART (SALA_LIMIT_PSTART, tests only): "<pid>=<epoch>" and "*=<epoch>" words, a start time instead of /proc.
PST = dict(w.split("=", 1) for w in (os.environ.get("PSTART") or "").split() if "=" in w)
def pstart(pid, reg):
    v = PST.get(pid, PST.get("*"))
    if v is not None: return int(v) if v.isdigit() else 0
    try:
        st = open("/proc/%s/stat" % pid).read(); ticks = int(st[st.rindex(")") + 2:].split()[19])
        bt = next(int(l.split()[1]) for l in open("/proc/stat") if l.startswith("btime "))
        return int(bt + ticks / os.sysconf("SC_CLK_TCK"))
    except Exception: pass
    try: return int(reg.get("startedAt") or 0) // 1000
    except Exception: return 0
# every live pane: its lane, its newest record, its normal records (the lane's successes: from its process on) and when its run of errors began
live = {}
for line in sys.stdin:
    parts = line.rstrip("\n").split("|")
    if len(parts) != 3: continue
    s, pid, lane = parts
    if not s or " " in s or not pid.isdigit() or not lane or " " in lane: continue
    try: reg = json.load(open(os.path.join(RD, pid + ".json")))
    except Exception: continue
    u = str(reg.get("sessionId") or "")
    if not reg.get("tmux") or not u or u in live: continue
    c = glob.glob(os.path.join(glob.escape(SP), "*", glob.escape(u) + ".jsonl"))
    r = []
    if c:
        p = max(c, key=os.path.getmtime)
        if os.path.getmtime(p) >= now - LB: r = recs(p)
    live[u] = {"s": s, "pid": pid, "lane": lane, "r": r, "kind": r[-1][1] if r else "", "pst": pstart(pid, reg)}; pseen[u] = now   # a pane's conversation, for the lookback
for u in list(pseen):
    if pseen[u] < now - LB: del pseen[u]
fams = {""} | {fam(x[3]) for i in live.values() for x in i["r"] if x[1] == "err"} | {fam(p.get("lim", "")) for p in panes.values()}
lanecur = {}   # "<lane>|<model fam>" → the successes seen in the tails on that lane, of that model (every model for "")
for u, i in live.items():
    for e, k, _, _, _, _, model in i["r"]:
        if k != "ok": continue
        pok[u] = max(pok.get(u, 0), e)
        if e < i["pst"]: continue   # made before this process, maybe on another lane: the pane's own, not its lane's
        for f in fams:
            if f and f not in model: continue
            lanecur.setdefault(i["lane"] + "|" + f, []).append(e)
for key, es in lanecur.items(): laneok[key] = max(laneok.get(key, 0), max(es))
def lane_before(lane, lim, t):  # the lane's newest success before t (the tails, and earlier runs' memory when it is before t)
    key = lane + "|" + fam(lim); m = laneok.get(key, 0)
    return max([e for e in lanecur.get(key, []) if e < t] + [m if m < t else 0])
for u, i in live.items():
    r = i["r"]; i.update({"since": 0, "err": "", "errat": 0, "reset": 0, "lim": "", "elane": i["lane"], "okafter": 0})
    if r and r[-1][1] == "err":
        i["errat"], i["reset"], i["lim"], i["err"] = r[-1][0], r[-1][2], r[-1][3], r[-1][4]
        sl = str(seen[u].get("lane") or "") if (seen.get(u) or {}).get("e") == i["err"] else ""
        if not sl and i["lim"] not in API_KINDS and i["errat"] >= i["pst"]: seen[u] = {"e": i["err"], "lane": i["lane"]}; sl = i["lane"]   # written by this process: hit on the lane it runs on
        i["elane"] = err_lane(i["lim"], i["lane"], sl)   # the lane the error belongs to (the header)
        floor = max(pok.get(u, 0), (done.get(u) or {}).get("at", 0), lane_before(i["elane"], i["lim"], i["errat"]))   # a lift by reset counts from the lift
        i["since"] = min([e for e, k, _, _, _, _, _ in r if k == "err" and e > floor] or [r[-1][0]])
    elif r:
        lerr = max([e for e, k, _, _, _, _, _ in r if k == "err"] or [0])
        i["okafter"] = min([e for e, k, _, _, _, _, _ in r if k == "ok" and e > lerr] or [r[-1][0]])
episode = st.get("episode", 0)
for u in list(pok):
    if u not in live: del pok[u]   # retired or gone: dropped without a word
for u in list(panes):
    if u not in live and not RELAUNCH: del panes[u]   # retired or gone: dropped without a word; mid-relaunch (no claude process this tick) its stop is kept
for u in list(seen):
    if u not in pseen: del seen[u]   # kept while the conversation is in the lookback: a pane relaunched elsewhere still knows the lane its error was hit on
for u in list(done):
    if u not in live or live[u]["kind"] != "err": del done[u]   # gone, or went on: a later error is a new stop
lifted = False
for u in sorted(panes, key=lambda x: panes[x]["since"]):
    if u not in live: continue   # mid-relaunch: judged once it is back
    i, p = live[u], panes[u]; p.setdefault("lane", i["lane"]); p.setdefault("lim", "seven_day")   # a state from before the lanes
    if i["kind"] == "ok" and (i["r"][-1][0] >= i["pst"] or i["lane"] != p["lane"]):   # a normal record after its error: nothing to tell it
        t, tell = i["okafter"], 0
        why = "moved" if i["lane"] != p["lane"] else ("reset" if p["reset"] and t >= p["reset"] else "lifted")
    elif i["kind"] == "ok":   # its newest normal record predates its process: lifted only by its lane's success since its error
        lm = laneok.get(i["lane"] + "|" + fam(p["lim"]), 0)
        if lm <= max([e for e, k, _, _, _, _, _ in i["r"] if k == "err"] or [p["since"]]): continue
        t, tell, why = lm, 0, ("reset" if p["reset"] and lm >= p["reset"] else "lifted")
    elif i["lane"] != p["lane"]: t, tell, why = now, 1, "moved"
    else:
        lm = laneok.get(i["lane"] + "|" + fam(p["lim"]), 0)   # the lane's newest success (this run's tails and earlier runs')
        if lm <= i["errat"]: continue
        t, tell, why = lm, 1, ("reset" if p["reset"] and now >= p["reset"] and lm >= p["reset"] else "lifted")
    print("lift", i["s"], i["pid"], u, i["err"] or "-", t, why, i["lane"], p["lane"], p["lim"], p["since"], p["reset"], tell)
    if tell: done[u] = {"e": i["err"], "at": now}
    del panes[u]; lifted = True
if lifted and not panes and episode:
    print("units", episode); episode = 0
if not panes: episode = 0
for u, i in sorted(live.items(), key=lambda x: x[1]["since"]):
    if i["kind"] != "err": continue
    print("cur", u, i["pid"], i["s"], i["err"])
    if u in panes or (done.get(u) or {}).get("e") == i["err"]: continue
    # not among the stopped panes, on an error that is not this lane's now (the header): a pane that moved (relaunched with the
    # same conversation; its api stop dropped mid-relaunch), or one whose old error's lane has worked since —
    # lifted and told once, never a stop on the lane it runs on
    lm = laneok.get(i["lane"] + "|" + fam(i["lim"]), 0)
    if i["elane"] != i["lane"]: t, why = now, "moved"
    elif i["errat"] < i["pst"] and lm > i["errat"]: t, why = lm, ("reset" if i["reset"] and lm >= i["reset"] else "lifted")
    else: t, why = 0, ""
    if why:
        print("lift", i["s"], i["pid"], u, i["err"], t, why, i["lane"], i["elane"], i["lim"], i["since"], i["reset"], 1)
        done[u] = {"e": i["err"], "at": now}; continue
    if now - i["since"] < CONFIRM: continue
    panes[u] = {"s": i["s"], "since": i["since"], "reset": i["reset"], "lane": i["elane"], "lim": i["lim"], "e": i["err"], "rlane": i["lane"]}   # rlane: the lane the pane RUNS on ("lane" is the error's: an API kind is always the api lane's); the back agents' lane rule asks which lane's cap a pane stopped on (back_lane_stopped)
    episode = min(episode or i["since"], i["since"])
    print("stop", i["s"], i["elane"], i["lim"], i["reset"], i["since"])
# the headless runs: every transcript written in the lookback that was no pane's (not now, not at any tick of the lookback:
# a retired pane's last error is not a headless run) and whose newest record `claude -p` made (entrypoint "sdk-cli"; a
# session started by hand is not one), each judged on its own and named by what started it (the header)
U = None
def units():  # every user service's last run, by unit: description, explicit working directory, start/exit/active, result
    global U
    if U is not None: return U
    U = {}
    try:
        run = lambda *a: subprocess.run(["systemctl", "--user", *a], capture_output=True, text=True, timeout=20).stdout
        names = [l.split()[0] for l in run("list-units", "--all", "--type=service", "--plain", "--no-legend").split("\n") if l.strip()]
        out = run("show", "--timestamp=unix", "-p", "Id,Type,ActiveState,Description,WorkingDirectory,ExecMainStartTimestamp,ExecMainExitTimestamp,ActiveEnterTimestamp,Result", "--", *names) if names else ""
    except Exception: out = ""
    for block in out.split("\n\n"):
        d = dict(l.split("=", 1) for l in block.split("\n") if "=" in l)
        if not d.get("Id"): continue
        ts = lambda k: int(d.get(k, "").lstrip("@")) if d.get(k, "").lstrip("@").isdigit() else 0
        wd = d.get("WorkingDirectory", ""); wd = "" if wd.startswith("!") else wd.lstrip("-")   # "!<dir>": the implicit default, no match
        U[d["Id"]] = {"desc": d.get("Description", ""), "wd": wd, "type": d.get("Type", ""), "state": d.get("ActiveState", ""), "start": ts("ExecMainStartTimestamp"), "exit": ts("ExecMainExitTimestamp"), "active": ts("ActiveEnterTimestamp"), "result": d.get("Result", "")}
    return U
EXCL = {"sala-watch.service", "salamander-watch.service", "sala-heartbeat.service"}   # sala's own ticks: they run no claude
JBUDGET = int(os.environ.get("LW_JOURNAL") or 40)
HEADLESS_EP = {"sdk-cli"}   # the newest record's entrypoint that makes a pane-less transcript a headless run: `claude -p` alone (the header)
OWN = tuple(x for x in (os.environ.get("OWN_PREFIXES") or "sala-,salamander-").split(",") if x)   # SALA_OWN_UNIT_PREFIXES: the unit-name prefixes that count as ours
def ours(i, u): return i.startswith(OWN) and i not in EXCL and u["type"] == "oneshot"
def compat(u, cwd): return 0 if u["wd"] and u["wd"] == cwd and cwd != HOME else (1 if not u["wd"] and cwd == HOME else 2)   # the unit's directory against the run's
def journal(at):  # → [(unit, closest epoch)] the user journal shows starting or writing within a minute of at
    global JBUDGET
    if JBUDGET <= 0: return None
    JBUDGET -= 1
    try: out = subprocess.run(["journalctl", "--user", "-o", "json", "--output-fields=USER_UNIT,_SYSTEMD_USER_UNIT", "--since", "@%d" % (at - 60), "--until", "@%d" % (at + 60), "--no-pager", "-q"], capture_output=True, text=True, timeout=30).stdout
    except Exception: return []
    best = {}
    for l in out.split("\n"):
        try: o = json.loads(l); t = int(o.get("__REALTIME_TIMESTAMP") or 0) // 1000000
        except Exception: continue
        for f in ("USER_UNIT", "_SYSTEMD_USER_UNIT"):
            v = o.get(f)
            if isinstance(v, str) and v.endswith(".service") and abs(t - at) < abs(best.get(v, at + 10**9) - at): best[v] = t
    return sorted(best.items())
def starter(at, cwd):  # → the unit that ran this transcript ("" none; None: not now, the journal budget is spent), ranked as the header says
    uu = units(); near = lambda u: u["start"] and (abs(u["start"] - at) <= 60 or (u["start"] <= at and (u["exit"] >= at if u["exit"] else u["state"] == "active")))
    cand = [(0 if near(u) else 1, i) for i, u in uu.items() if u["wd"] and u["wd"] == cwd and cwd != HOME]   # its explicit WorkingDirectory
    if cand: return min(cand)[1]
    cand = [(compat(u, cwd), abs(u["start"] - at), i) for i, u in uu.items() if ours(i, u) and near(u)]       # the unit's last run is at this time
    if cand and min(cand)[0] <= 1: return min(cand)[2]   # its directory fits; one that works elsewhere is weak: the journal may know better
    j = journal(at)
    if j is None: return None
    cand += [(compat(uu[i], cwd), abs(t - at), i) for i, t in j if i in uu and ours(i, uu[i])]
    return min(cand)[2] if cand else ""
for d in glob.glob(os.path.join(glob.escape(SP), "*")):
    for p in glob.glob(os.path.join(glob.escape(d), "*.jsonl")):
        u = os.path.basename(p)[:-6]
        if u in pseen: continue
        try:
            if os.path.getmtime(p) < now - LB: continue
        except OSError: continue
        r = recs(p, HTAIL)
        if not r: continue
        if ents[(p, HTAIL)][-1] not in HEADLESS_EP:   # a session started by hand ("cli"), or no entrypoint at all: no headless run (the header)
            hseen.pop(u, None); continue
        e, k, reset, lim, _, cwd, _ = r[-1]
        if (hseen.get(u) or {}).get("at") != e or hseen[u].get("k") != k:   # first seen with this newest record: resolve its starter now
            un = starter(e, cwd)
            if un is None: continue   # the journal budget is spent: next tick
            hseen[u] = {"at": e, "k": k, "lim": lim, "reset": reset, "cwd": cwd, "unit": un, "ok": max([x[0] for x in r if x[1] == "ok"] or [0])}
        hseen[u]["t"] = now
for u in list(hseen):
    if hseen[u].get("t", 0) < now - 2 * LB or hseen[u]["at"] < now - LB: del hseen[u]
by = {}   # starter → its runs on the error and its last success (a transcript's, or the unit's own later successful run)
for u, h in hseen.items():
    if h.get("t") != now: continue
    key = h["unit"] or "cwd:" + h["cwd"]; b = by.setdefault(key, {"runs": [], "ok": 0, "cwd": h["cwd"], "unit": h["unit"]})
    if h["k"] == "err": b["runs"].append((h["at"], h["lim"], h["reset"], u))
    b["ok"] = max(b["ok"], h.get("ok", 0))   # the transcript's last success, before or after its error
for key, b in by.items():
    un = units().get(b["unit"]) if b["unit"] else None
    if un and un["result"] == "success": b["ok"] = max(b["ok"], un["exit"], un["active"])
    b["runs"] = [x for x in b["runs"] if x[0] > b["ok"]]   # a run that later succeeded is dropped
for key in list(headless):
    if key not in by or not by[key]["runs"] or by[key]["ok"] > headless[key]: del headless[key]   # gone, or works again: the episode ended
for key, b in sorted(by.items()):
    if not b["runs"] or key in headless: continue
    first = min(b["runs"])
    if now - first[0] < CONFIRM: continue   # as a pane: a run may still go through
    headless[key] = first[0]
    if b["unit"]:
        un = units()[b["unit"]]; nm = b["unit"][:-8] if b["unit"].endswith(".service") else b["unit"]
        name = "%s (%s)" % (un["desc"], nm) if 0 < len(un["desc"]) <= 40 else nm
    else: name = "a Claude run from the home folder (%s)" % HOME if b["cwd"] == HOME else "a Claude run from %s" % (b["cwd"] or "an unknown folder")
    print("headless", first[0], first[1], first[2], len(b["runs"]), b["unit"] or "-", name)
tmp = STF + ".tmp"
with open(tmp, "w") as f: json.dump({"panes": panes, "done": done, "seen": seen, "pok": pok, "laneok": laneok, "headless": headless, "pseen": pseen, "hseen": hseen, "episode": episode}, f)
os.replace(tmp, STF)
PYL
LW_PY=${LW_PY%$'\n'}
lw_scan() {  # panes on stdin; RELAUNCH=1 while a relaunch holds the recycle lock (a stopped pane with no claude process this tick keeps its stop)
    SP="$SALA_PROJECTS" RD="$SALA_REG_DIR" STF="$LW_STATE" LB="$SALA_LIMIT_LOOKBACK" CONFIRM="$SALA_LIMIT_CONFIRM" PSTART="${SALA_LIMIT_PSTART:-}" OWN_PREFIXES="${SALA_OWN_UNIT_PREFIXES:-sala-,salamander-}" \
        RELAUNCH="$(recycle_locked && echo 1 || echo 0)" python3 -c "$LW_PY"; }
lw_names() { local o; o=$(printf "%s, " "${@:1:20}"); o=${o%, }; [ $# -gt 20 ] && o="$o and $(( $# - 20 )) more"; echo "$o"; }   # <name…> → "a, b, c" (twenty at most)
lw_units() {  # <since epoch> → each of sala's oneshot units that failed at or after it, reset and started; its name on stdout
    local u ts
    systemctl --user list-units --state=failed --plain --no-legend 'sala-*' 'salamander-*' 2>/dev/null | awk '{print $1}' | while read -r u; do
        case "$u" in sala-watch.service|sala-auto-*) continue;; sala-*.service|salamander-*.service) ;; *) continue;; esac
        [ "$(systemctl --user show -p Type --value "$u" 2>/dev/null)" = oneshot ] || continue
        ts=$(systemctl --user show -p StateChangeTimestamp --timestamp=unix --value "$u" 2>/dev/null); ts=${ts#@}
        case "$ts" in ''|*[!0-9]*) continue;; esac
        [ "$ts" -ge "$1" ] || continue
        if systemctl --user reset-failed "$u" 2>/dev/null && systemctl --user start --no-block "$u" 2>/dev/null; then
            wlog "limit: $u had failed at $(lw_when "$ts"), during the stop — reset and started"; echo "${u%.service}"
        else wlog "limit: $u failed during the stop, but resetting or starting it failed"; fi
    done
}
lw_tell() {  # <session> <pid> <stop since> <why> <lane it runs on> → told | busy | unreached
    is_idle "$2" || { echo busy; return; }
    local sock; sock=$(session_socket "$2")
    if [ -n "$sock" ] && session_push "$sock" "[sala] Your lane${5:+ ($5)} works again: $4. Your last turn ended on the usage-limit error (stopped since $(lw_when "$3")): re-read your last incoming message and handle it now." 2>/dev/null; then
        wlog "limit: told $1 (pid $2) to handle its last message ($4)"; echo told
    else echo unreached; fi
}
# lw_why <why> <lane now> <lane at the error> <limit> <reset> → the reason a pane's calls work again, for the post and the pane:
# "moved to the <name> lane", "the <name> weekly limit reset at Wed Jan 7th 14:00", "the <name> weekly limit lifted early", "API credit
# was added", "the API rate limit lifted" (the api lane's kinds have no reset to be early to)
lw_why() {
    case "$1" in
        moved) echo "moved to the $(lane_shown "$2") lane";;
        reset) echo "the $(lw_limit "$3" "$4") reset at $(lw_when "$5")";;
        *) case "$4" in credit) echo "API credit was added";; rate) echo "the API rate limit lifted";; *) echo "the $(lw_limit "$3" "$4") lifted early";; esac;;
    esac
}
limit_tick() {
    [ "$SALA_LIMIT_ALERT" = on ] || [ "$SALA_LIMIT_RESUME" = on ] || return 0
    ( flock -n 8 || exit 0; lw_locked ) 8>>"$SALA_LOG_DIR/salamander-limit.lock"
}
lw_locked() {
    local now out l t s pid u e why lane elane lim since res r n=0 b=() keep=() told=() busy=() unr=() went=() units=() k kinds=() lanes=() cwd lift_at=0
    local -A gsince=() gnames=() gcount=()
    _now_r now
    out=$(lw_panes | lw_scan) || { wlog "limit: the transcript scan failed"; return 0; }
    # the scan's lines by kind, once (a grep or an awk per kind and per use)
    local ln_ lift_txt="" stop_txt="" head_txt="" units_ts="" cur_txt="" c1 c2 c3 c4 c5
    while IFS= read -r ln_; do
        case "$ln_" in
            "lift "*) lift_txt+="$ln_"$'\n' ;; "stop "*) stop_txt+="$ln_"$'\n' ;; "headless "*) head_txt+="$ln_"$'\n' ;;
            "units "*) [ -n "$units_ts" ] || { units_ts=${ln_#units }; units_ts=${units_ts%% *}; } ;; "cur "*) cur_txt+="$ln_"$'\n' ;;
        esac
    done <<< "$out"
    lift_txt=${lift_txt%$'\n'}; stop_txt=${stop_txt%$'\n'}; head_txt=${head_txt%$'\n'}
    ld_limit_tick   # the API credit used up sets the api lane dormant (the dormant record's signals, above)
    # the panes still to be told from an earlier lift: told once idle, while still on that error, until their time is up
    if [ -s "$LW_RESUME" ] && [ "$SALA_LIMIT_RESUME" = on ]; then
        while IFS='|' read -r u e t since why lane; do
            [ -n "$u" ] && [ "$now" -lt "${t:-0}" ] || continue
            l=""; while read -r c1 c2 c3 c4 c5 _; do if [ "$c1" = cur ] && [ "$c2" = "$u" ] && [ "$c5" = "$e" ]; then l="$c3 $c4"; break; fi; done <<< "$cur_txt"; [ -n "$l" ] || continue   # gone or went on
            read -r pid s <<< "$l"
            if recycle_locked; then keep+=("$u|$e|$t|$since|$why|$lane"); continue; fi
            case "$(lw_tell "$s" "$pid" "$since" "$why" "$lane")" in told) ;; *) keep+=("$u|$e|$t|$since|$why|$lane");; esac
        done < "$LW_RESUME"
        printf '%s\n' ${keep[@]+"${keep[@]}"} | grep . > "$LW_RESUME.tmp"; mv -f "$LW_RESUME.tmp" "$LW_RESUME"
    fi
    # the panes lifted this run: one post, a line per reason (by lane and limit), after telling the ones still on the error
    while read -r _ s pid u e t why lane elane lim since r tell; do
        [ -n "$s" ] || continue   # (an empty list is one empty line for a here-string)
        n=$((n + 1)); [ "$t" -gt "$lift_at" ] && lift_at=$t
        _ls=$(lane_shown "$lane"); case " ${lanes[*]-} " in *" $_ls "*) ;; *) lanes+=("$_ls");; esac   # the lanes they work on now (by display name), for the headline
        k="$elane|$lim"; gsince[$k]=$(( ${gsince[$k]:-$since} < since ? ${gsince[$k]:-$since} : since )); gcount[$k]=$(( ${gcount[$k]:-0} + 1 ))
        case "$why" in moved) k="moved|$lane|||";; reset) k="reset||$elane|$lim|$r";; *) k="lifted||$elane|$lim|";; esac
        case " ${kinds[*]-} " in *" $k "*) ;; *) kinds+=("$k");; esac; gnames[$k]="${gnames[$k]:-} $s"
        if [ "$tell" = 0 ]; then went+=("$s"); continue; fi
        [ "$SALA_LIMIT_RESUME" = on ] || continue
        why=$(lw_why "$why" "$lane" "$elane" "$lim" "$r")
        if recycle_locked; then res=busy; else res=$(lw_tell "$s" "$pid" "$since" "$why" "$lane"); fi   # a running recycle: as busy
        case "$res" in told) told+=("$s");; busy) busy+=("$s"); echo "$u|$e|$((now + SALA_LIMIT_RESUME_FOR))|$since|$why|$lane" >> "$LW_RESUME";; *) unr+=("$s");; esac
    done <<< "$lift_txt"
    if [ "$n" -gt 0 ]; then
        b=()
        for k in $(printf '%s\n' "${!gcount[@]}" | sort); do
            lane=${k%%|*}; lim=${k#*|}
            b+=("$(lw_had "$lane" "$lim" "$([ ${#gcount[@]} -gt 1 ] && echo "${gcount[$k]} of them" || echo them)" "${gsince[$k]}")")
        done
        for k in "${kinds[@]}"; do
            IFS='|' read -r why lane elane lim r <<< "$k"
            b+=("$(lw_why "$why" "$lane" "$elane" "$lim" "$r"): $(lw_names ${gnames[$k]})")
        done
        [ ${#told[@]} -gt 0 ] && b+=("told to handle their last incoming message: $(lw_names "${told[@]}")")
        [ ${#busy[@]} -gt 0 ] && b+=("busy, told once idle: $(lw_names "${busy[@]}")")
        [ ${#unr[@]} -gt 0 ] && b+=("could not be told (no messaging socket): $(lw_names "${unr[@]}")")
        if [ "$SALA_LIMIT_RESUME" = on ] && [ -n "$units_ts" ]; then
            mapfile -t units < <(lw_units "$units_ts")
            [ ${#units[@]} -gt 0 ] && b+=("re-run after failing during the stop: $(lw_names "${units[@]}")")
        fi
        # the headline names the lane ("API calls" read as the API credit alone, and the lane is what matters)
        if [ ${#lanes[@]} = 1 ]; then l="${lanes[0]} lane working again for $(plural "$n" pane) since $(lw_when "$lift_at")"
        else l="Working again on the $(lw_names "${lanes[@]}") lanes: $(plural "$n" pane) since $(lw_when "$lift_at")"; fi
        local lg="" l1 l2 l3 l4 l5 l6 l7; while read -r l1 l2 l3 l4 l5 l6 l7 _; do [ -n "$l1" ] && lg+="$l2($l7) "; done <<< "$lift_txt"
        wlog "limit: $l: $lg"
        [ "$SALA_LIMIT_ALERT" = on ] && notify "✅ *$l*" "${b[@]}"
    fi
    # newly stopped panes: one post for the run, a line per lane, limit and reset; the headless runs on it, or on their own
    n=0; gsince=(); gnames=(); kinds=(); lanes=(); b=()
    while read -r _ s lane lim r since; do
        [ -n "$s" ] || continue
        k="$lane|$lim|$r"; gsince[$k]=$(( ${gsince[$k]:-$since} < since ? ${gsince[$k]:-$since} : since )); gnames[$k]="${gnames[$k]:-} $s"; n=$((n + 1))
        l=$(lw_limit "$lane" "$lim"); case " ${kinds[*]-} " in *" $l "*) ;; *) kinds+=("$l");; esac
        _ls=$(lane_shown "$lane"); case " ${lanes[*]-} " in *" $_ls "*) ;; *) lanes+=("$_ls");; esac
    done <<< "$stop_txt"
    for k in $(printf '%s\n' "${!gnames[@]}" | sort); do
        IFS='|' read -r lane lim r <<< "$k"
        b+=("$(lane_shown "$lane") lane: $(lw_since "$lane" "$lim" "${gsince[$k]}")$(lw_resets "$lim" "$r"): $(lw_names ${gnames[$k]})")
    done
    [ "$n" -gt 0 ] && [ "$SALA_LIMIT_RESUME" = on ] && b+=("once calls work again for them, sala tells each one to handle its last incoming message")
    while read -r _ since lim r nruns un name; do
        [ -n "$name" ] || continue
        l="$name: $(lw_since - "$lim" "$since")"; [ "$nruns" -gt 1 ] && l="$l ($nruns runs so far)"; [ "$r" -gt 0 ] && l="$l, it says it resets $(lw_when "$r")"
        if [ "$un" != - ]; then b+=("outside the panes, $l; its next scheduled run tries again"); else b+=("outside the panes, $l; nothing retries it on its own"); fi
    done <<< "$head_txt"
    [ ${#b[@]} -gt 0 ] || return 0
    if [ "$n" -gt 0 ]; then
        local ws="" w1 w2 w3 w4
        while read -r w1 w2 w3 w4 _; do [ -n "$w1" ] && ws+="$w2($w3 $w4) "; done <<< "$stop_txt"
        while IFS= read -r w1; do [ -n "$w1" ] || continue; w1=${w1#* }; w1=${w1#* }; w1=${w1#* }; w1=${w1#* }; w1=${w1#* }; w1=${w1#* }; ws+="headless($w1) "; done <<< "$head_txt"
        wlog "limit: $(plural "$n" pane) stopped: $ws"
        if [ ${#lanes[@]} = 1 ]; then l="🚨 *${lanes[0]} lane stopped for $(plural "$n" pane): $(lw_names "${kinds[@]}")*"   # the lane first
        else l="🚨 *$(lw_names "${lanes[@]}") lanes stopped for $(plural "$n" pane)*"; fi
    else
        local ws="" w1
        while IFS= read -r w1; do [ -n "$w1" ] || continue; w1=${w1#* }; w1=${w1#* }; w1=${w1#* }; w1=${w1#* }; w1=${w1#* }; w1=${w1#* }; ws+="$w1; "; done <<< "$head_txt"
        wlog "limit: headless runs on the limit: $ws"
        l="⚠️ *A usage limit stops $(plural "${#b[@]}" run) outside the panes*"
    fi
    [ "$SALA_LIMIT_ALERT" = on ] && notify "$l" "${b[@]}"
    return 0
}
# NETWORK-STOP WAKE: a reboot with DNS down leaves panes whose first turn ended on "API Error: Can't reach the API server —
# check your internet or DNS (EAI_AGAIN)". That error ends the turn and nothing retries it, so they stay stopped after DNS is
# back, even though the revive post counts them as resumed. Like the usage-limit watch this takes no Claude turn and makes no API call. The reading is
# common.sh's net_scan (THE NETWORK STOP there: the record, the family of the text, what a stop and an episode are); every tick:
#  - each live pane whose newest assistant record is that error is a stopped pane; one the wake has already served in this
#    episode is left alone. The episode is its unbroken run of such errors, remembered by the epoch of its first (state:
#    SALA_LOG_DIR/salamander-net.state, conversation TAB first error TAB sent epoch, 0 = not yet), so a pane that works
#    again and stops again later is a new episode and is woken once more, and a woken turn that fails again on the same
#    error is not woken again. A conversation not seen on the error for SALA_NET_LOOKBACK is dropped from the state.
#  - THE WAKE: only when api.anthropic.com resolves (`getent hosts`, SALA_NET_DNS_WAIT seconds at most; asked only when a
#    pane is waiting) and the pane is idle (is_idle: a busy or unknown one is left to the next tick), ONE message through the
#    pane's own messaging socket (session_push, the delivery the usage-limit watch's resume and `sala cue` use: it arrives as
#    a turn, so the session answers; nothing is typed into the pane and no Enter is sent). A pane with no claude process or no
#    messaging socket is skipped without a word; a push that failed is tried again at the next tick. A recycle in flight
#    (the lock) pauses the step.
#  - The trace is the watch log, one line when a stop is first seen and one when the pane is woken; no post (the operator reads the
#    revive post, which names the count: lib/revive.sh and the post-boot report, NET_NOTE below).
# SALA_NET_WAKE=off: nothing is read or kept. `sala watch --net` runs this step alone.
: "${SALA_NET_WAKE:=on}"; : "${SALA_NET_HOST:=api.anthropic.com}"; : "${SALA_NET_DNS_WAIT:=5}"
NW_STATE="$SALA_LOG_DIR/salamander-net.state"
NW_TEXT="[sala] Your last turn ended on a network error (API unreachable). The network is back; continue what you were doing."
net_up() { timeout "$SALA_NET_DNS_WAIT" getent hosts "$SALA_NET_HOST" >/dev/null 2>&1; }
nw_get() { awk -F'\t' -v c="$1" '$1==c {print $2, $3; exit}' "$NW_STATE" 2>/dev/null; }   # <conversation> → "<first error epoch> <sent epoch>"
nw_put() {  # <conversation> <first error epoch> <sent epoch>: one atomic rewrite; entries not touched for SALA_NET_LOOKBACK are dropped with it
    local cut=$(( $(date +%s) - SALA_NET_LOOKBACK ))
    { awk -F'\t' -v c="$1" -v cut="$cut" '$1!=c && ($2>cut || $3>cut)' "$NW_STATE" 2>/dev/null; printf '%s\t%s\t%s\n' "$1" "$2" "$3"; } > "$NW_STATE.tmp.$$" && mv -f "$NW_STATE.tmp.$$" "$NW_STATE"
}
net_tick() {
    [ "$SALA_NET_WAKE" = on ] || return 0
    ( flock -n 8 || exit 0; nw_locked ) 8>>"$SALA_LOG_DIR/salamander-net.lock"
}
nw_locked() {
    local rows s pid u first last e_first e_sent up="" sock now
    recycle_locked && return 0   # panes are being relaunched: judged once they are back
    rows=$(lw_panes | net_scan 2>/dev/null) || return 0
    [ -n "$rows" ] || return 0
    now=$(date +%s)
    while read -r _ s pid u first last; do
        read -r e_first e_sent <<< "$(nw_get "$u")"
        if [ "${e_first:-}" != "$first" ]; then   # a stop not seen before: a new episode
            nw_put "$u" "$first" 0; e_sent=0
            wlog "network: $s stopped on a network error since $(lw_when "$first") — woken once the network is back"
        fi
        [ "${e_sent:-0}" -gt 0 ] && continue      # woken in this episode already
        if [ -z "$up" ]; then net_up && up=1 || up=0; fi
        [ "$up" = 1 ] || continue
        is_idle "$pid" || continue
        sock=$(session_socket "$pid"); [ -n "$sock" ] || continue
        if session_push "$sock" "$NW_TEXT" 2>/dev/null; then
            nw_put "$u" "$first" "$now"; wlog "network: woke $s (pid $pid), stopped on a network error since $(lw_when "$first")"
        fi
    done <<< "$rows"
    return 0
}
# THE DORMANT RECORD'S SIGNALS (the record and what reads it: common.sh, "THE
# DORMANT RECORD"). The watch KEEPS one record per lane, active or dormant, from detections it already makes — no new network
# call, no Claude turn, no test call to find out whether a lane works:
#  - SUBSCRIPTION-2 (a seat-based lane): the sign-in watch's own verdict for the lane is WRONG (sw_judge: not signed in, signed in
#    with no subscription, or on another subscription or organization than the seat of lane_expect) — "no seat"; or the usage
#    check was REFUSED: sala-web's usage endpoint answered HTTP 403 and saved errorKind "refused" in its quota-team.json
#    (web/src/sala_web/quota.py), newer than the lane's last change in the record. UNVERIFIED: what `claude auth status --json`
#    prints for a seat-based directory whose seat was removed has no recorded sample; every shape it can take that is not
#    "loggedIn, the expected subscriptionType, the expected orgName" is a wrong verdict and counts, and so does a refusal — but
#    whether the CLI keeps reporting the subscription for a seatless login, or the usage endpoint answers 403 rather than
#    401, is a guess.
#  - SUBSCRIPTION-1: the same verdict is wrong — the login no longer reports the subscription it expects (lane_expect subscription-1).
#  - API and SDK (one key, one record: the api lane): the limit watch's state has a pane stopped on the API credit ("Credit
#    balance is too low", kind credit — the record the scan already reads); since = the pane's first error of the stop. A key
#    refused (401/403) is the sign-in watch's alert and is not a signal here.
# Each signal sets the lane dormant ONCE (lane_dormant_set is a no-op on a lane already dormant, so the reason and since of the
# first stand), with by=signal. COMING BACK: a login lane (subscription-1, subscription-2) set by a signal is looked at again once a day
# (SALA_LANE_REVIVE_EVERY) with the sign-in check the watch makes anyway (free): right -> active, one line in the log. A lane set
# by hand, and the API lane (api, sdk), never come back on their own: `sala lane active <lane>`. THE POST: once per dormant
# episode, when sessions are still recorded on the lane (ld_post_tick; the memory is the record's "posted" column): which lane,
# why, since when, how many sessions, and that moving them is up to the operator. Nothing here moves, relaunches or stops a pane ITSELF:
# THE LANE FALLBACK (the automatic fallback; common.sh lane_fallback_auto, lib/lane.sh) queues, the moment a lane turns
# dormant, ONE operation (`sala op lane fallback <lane> --from sala-watch`) that moves the lane's sessions, default and jobs to its
# fallback lane at their next idle moment, and posts ONE notice; that notice replaces this post (claimed below). With no usable
# fallback (none set, or itself dormant or not ready) nothing moves, and this post carries one line saying why (ld_post_tick).
declare -A LD_NOFB=()   # <lane> → why the fallback was not queued, for the episode's one post
ld_fallback() {  # <lane> — the lane went dormant just now: queue its sessions' move onto its fallback lane
    local r rc; r=$(lane_fallback_auto "$1" signal); rc=$?
    case "$rc" in
        0) lane_dormant_claim_post "$1" >/dev/null 2>&1 || true   # the operation's own notice names the lane, the fallback and every session: no second post
           wlog "lanes: the $1 lane's sessions move to its fallback lane — op $r queued (one notice when it is done)" ;;
        1) LD_NOFB[$1]=$r; wlog "lanes: the $1 lane is dormant and nothing is moved: $r" ;;
    esac   # 2: nothing is on the lane (the post waits for a session) · 3: SALA_LANE_FALLBACK_AUTO is off (the post says moving is up to the operator)
    return 0
}
ld_signal() {  # <lane> <reason> <since epoch> <what was seen> -> the lane dormant, logged once
    lane_dormant_set "$1" "$2" signal "$3"
    case $? in 0) wlog "lanes: the $1 lane is dormant — $2 ($4)"
        case "$1" in subscription-1|subscription-2) sw_set "$1.revived" "";; esac   # a new episode: its first daily look is a day after it began
        ld_fallback "$1";;
    esac
    return 0
}
ld_login_wrong() {  # <lane> <since epoch> <seen>: the sign-in verdict for a login lane is wrong
    case "$(lane_norm "$1")" in subscription-2) ld_signal subscription-2 "no seat" "$2" "sign-in check: $3";; subscription-1) ld_signal subscription-1 "login no longer reports Max" "$2" "sign-in check: $3";; esac   # "Max": Anthropic's plan name, what the login reports
}
# a login lane set dormant by a signal is looked at again every SALA_LANE_REVIVE_EVERY with the verdict the sign-in check just
# gave (right -> active). The look is stamped in the sign-in state (<lane>.revived); the first one is a day after the lane went dormant.
ld_login_right() {  # <lane>
    lane_dormant "$1" && [ "$(lane_state_field "$1" 6)" = signal ] || return 0
    local now last; now=$(date +%s); last=$(sw_get "$1.revived"); [ -n "$last" ] || last=$(lane_iso_epoch "$(lane_state_field "$1" 4)")
    [ $(( now - last )) -ge "$SALA_LANE_REVIVE_EVERY" ] || return 0
    sw_set "$1.revived" "$now"
    lane_dormant_clear "$1" "the sign-in check is right again (the daily look)" && wlog "lanes: the $1 lane is active again — the daily look found the sign-in right"
    return 0
}
ld_login_looked() {  # <lane>: the sign-in check is still wrong; a daily look that finds so is stamped, the next one is a day on
    lane_dormant "$1" && [ "$(lane_state_field "$1" 6)" = signal ] || return 0
    local now last; now=$(date +%s); last=$(sw_get "$1.revived"); [ -n "$last" ] || last=$(lane_iso_epoch "$(lane_state_field "$1" 4)")
    [ $(( now - last )) -ge "$SALA_LANE_REVIVE_EVERY" ] || return 0
    sw_set "$1.revived" "$now"; wlog "lanes: the daily look: the $1 lane is still wrong, so it stays dormant"
    return 0
}
# the usage check refused: sala-web's saved answer for the lane says so, and is newer than the record's last change for the lane
ld_usage_refused() {  # <lane> -> the epoch of that saved answer, nothing when there is no such refusal
    local f="$SALA_WEB_STATE_DIR/quota-$1.json" m c lo
    if [ ! -r "$f" ]; then _lane_varid_old_r lo "$1"; [ -n "$lo" ] && f="$SALA_WEB_STATE_DIR/quota-${lo,,}.json"; fi   # a saved answer from before the rename carries the old word in its name
    [ -r "$f" ] || return 1
    python3 -c 'import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception: sys.exit(1)
sys.exit(0 if isinstance(d, dict) and d.get("errorKind") == "refused" else 1)' "$f" 2>/dev/null || return 1
    m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null) || return 1
    c=$(lane_state_field "$1" 4); c=${c:+$(lane_iso_epoch "$c")}
    [ "$m" -gt "${c:-0}" ] 2>/dev/null || return 1
    echo "$m"
}
ld_usage_tick() {  # subscription-2 (Team): a refused usage check sets it dormant
    lane_dormant subscription-2 && return 0
    local m; m=$(ld_usage_refused subscription-2) || return 0
    ld_signal subscription-2 "usage check refused" "$m" "sala-web's saved usage answer: refused"
}
# the API credit: a pane the limit watch has stopped on it (the state the scan just wrote)
ld_limit_tick() {
    lane_dormant api && return 0
    local since c st=""; { IFS= read -r -d '' st < "$LW_STATE"; } 2>/dev/null || :
    [[ $st == *credit* ]] || return 0   # the scan's state names no credit stop: python3 would print nothing (one python3 start per tick saved)
    since=$(python3 -c 'import json, sys
try: panes = json.load(open(sys.argv[1])).get("panes") or {}
except Exception: sys.exit()
s = [int(p.get("since") or 0) for p in panes.values() if isinstance(p, dict) and p.get("lane") == "api" and p.get("lim") == "credit"]
if s: print(min(s))' "$LW_STATE" 2>/dev/null)
    [ -n "$since" ] || return 0
    [ "$since" -gt 0 ] 2>/dev/null || since=$(date +%s)
    # a stop that began before the lane was last set active (credit added, `sala lane active api`) is the old episode, still in the
    # state until its panes are lifted: not a new signal, or the lane would be dormant again one tick after it was set active
    c=$(lane_state_field api 4); c=${c:+$(lane_iso_epoch "$c")}
    [ "$since" -gt "${c:-0}" ] || return 0
    ld_signal api "credit used up" "$since" "the limit watch has a pane stopped on \"Credit balance is too low\""
}
# THE ONE POST of a dormant episode: sessions are still recorded on the lane. Claimed in the record first (so two ticks never both
# post), then sent through the watch's notify; no sessions on it, no post, and the episode stays unposted until some are.
ld_post_tick() {
    [ -r "$SALA_LANE_STATE" ] || return 0
    local l label why since n names line f2 todo="" nofb
    # the dormant lanes not yet posted (state dormant, posted column empty), read by the shell: the awk that listed them was a process per tick
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line//$'\t'/$'\x01'}; IFS=$'\x01' read -r l f2 _ _ f5 _ <<< "$line"; _lane_norm_r l "$l"
        [ "$f2" = dormant ] && [ -z "$f5" ] && todo+="$l"$'\n'
    done < "$SALA_LANE_STATE"
    while IFS= read -r l; do
        [ -n "$l" ] || continue
        names=$(lane_sessions_on "$l"); n=$(_nlines "$names"); [ -n "$names" ] || n=0
        [ "$n" -gt 0 ] || continue
        lane_dormant_claim_post "$l" || continue
        label=$(lane_label "$l"); why=$(lane_state_field "$l" 3); since=$(lane_day "$(lane_state_field "$l" 4)")
        # the lane fallback's one alert line when it moves nothing (lane_fallback_auto said why in this process, else the same check now)
        nofb="${LD_NOFB[$l]:-}"; if [ -z "$nofb" ] && [ "${SALA_LANE_FALLBACK_AUTO:-on}" != off ]; then nofb=$(lane_fallback_pick "$l") && nofb=""; fi
        wlog "lanes: posting the dormant $l lane: $(plural "$n" session) still on it"
        notify "⚠️ *The $label lane is dormant*" \
            "${why:+$why }since $since, $(plural "$n" session) $([ "$n" = 1 ] && echo is || echo are) still on it; moving them is your call" \
            ${nofb:+"not moved automatically: $nofb"} \
            "on it: $(lw_names $names)" \
            "to move one: \`sala lane <lane> <session>\`; to move them all to the lane's fallback: \`sala lane fallback $l\`; to bring the $label lane back once it works: \`sala lane active $l\`"
    done <<< "$todo"
    return 0
}
# SIGN-IN WATCH (watch and alert): a lane's login lives in its config directory
# (common.sh, lanes: subscription-1 in ~/.claude, subscription-2 in SALA_LANE_TEAM_DIR), and that directory holds ONE
# login, so a /login typed in one pane, or `claude auth login` in a shell without CLAUDE_CONFIG_DIR, re-signs the whole lane:
# every pane on it moves to the new account at its next relaunch, and that day a lane sat on the wrong account unnoticed. The
# way to change one pane's account is `sala lane <lane> <session>`; to re-sign a lane on purpose, `CLAUDE_CONFIG_DIR=<its dir>
# claude auth login --claudeai` in the web UI's Shell. This step reads what each lane is signed in to and alerts when it is not what the
# table in common.sh (lane_expect: SALA_LANE_<LANE>_SUBSCRIPTION, SALA_LANE_<LANE>_ORG) says. No Claude turn.
#  - THE LOGIN LANES, every SALA_SIGNIN_EVERY at most (the CLI's start-up is the cost): `claude auth status --json` in the
#    lane's directory (CLAUDE_CONFIG_DIR, unset for subscription-1), with no API key or token in its environment (an ANTHROPIC_API_KEY
#    there makes it report authMethod "api_key" and no subscription, whatever the directory holds). ITS SHAPE: signed in → {"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty",
#    …,"configDirectory":"/home/alex/.claude","email":"…","orgId":"…","orgName":"…","subscriptionType":"max"} (a seat-based login: orgName
#    "ACME", subscriptionType "team"), exit 0; not signed in → {"loggedIn":false,"authMethod":"none",…}, exit 1, and a
#    CLAUDE_CONFIG_DIR that is only a path gets a `backups/` folder made in it, so a lane's directory is asked only when it
#    exists and holds a login (.credentials.json, as lane_check reads it); a key in the environment → authMethod "api_key",
#    no subscriptionType. The lane is RIGHT when subscriptionType is the expected one and, where an organization is expected,
#    orgName is that organization; WRONG when it is not signed in, signed in with no subscription, or on another subscription
#    or organization; UNKNOWN when the CLI gave no JSON (missing, hung past 30 s, an older CLI without the verb). the
#    seat-based lane is asked whenever its directory exists (a signed-out directory is a change: its panes would sit at a
#    login screen); subscription-1 always.
#  - THE API LANE: the key file (SALA_LANE_API_KEY_FILE) must be there and non-empty, looked at every tick, and the key must be
#    accepted by the Messages API: one request of max_tokens 1 to the newest haiku the API lists, with the workspace header
#    from SALA_LANE_API_WORKSPACE_FILE when that file exists, at most every SALA_SIGNIN_API_EVERY (an hour), sent by python3
#    reading the files itself (the key is in no argv, log or output). The model (the latest one unless one is
#    given explicitly; the API has no latest alias for an id): SALA_SIGNIN_API_MODEL when set, used
#    as is; unset or empty, the same python first lists the models (GET /v1/models?limit=100, the same key and workspace
#    headers, beside the Messages URL) and takes the haiku with the newest created_at (the first listed on a tie), so each
#    hourly probe is one tiny GET more. Any failure of that listing (an error status, no haiku, no network, bad JSON) falls
#    back to the pin SW_API_MODEL_PIN and never decides the verdict by itself, except a 401/403: the key is refused, the
#    same verdict the Messages call would give, which is then not made. RIGHT on any answer but 401/403: a 400 ("credit balance
#    is too low", for example) or a 404 is a key the API accepted and has nothing to do with the sign-in; WRONG
#    on 401/403 (the key refused) or no key file; UNKNOWN on 429, a 5xx, a timeout or no network. Asked only where the lane
#    is in use: the key file exists, a session's row or the default is api or sdk.
#  - ONE POST PER CHANGE EPISODE, per lane: a lane found wrong is posted once (the lane, what was expected, what was seen and
#    since when, the fix), again only when what is seen changes to another wrong state or after it was right in between;
#    "signed in correctly again" once when it is right again. An unknown look neither alerts nor clears (logged once per
#    reason). The lanes that change in one tick share one post. Plain words, no email or id in a post (a personal login's
#    organization is named after its email: it is said as "a personal organization").
# State: SALA_STATE_DIR/lane-signin.state (beside lanes.tsv: per lane what was last seen and since when, what was posted, when
# the logins and the key were last asked), key=value like the watch state; its own flock. Off (SALA_SIGNIN_ALERT=off): nothing
# is asked or kept.
: "${SALA_SIGNIN_ALERT:=on}"; : "${SALA_SIGNIN_EVERY:=300}"; : "${SALA_SIGNIN_API_EVERY:=3600}"
: "${SALA_SIGNIN_API_MODEL:=}"; : "${SALA_SIGNIN_API_URL:=https://api.anthropic.com/v1/messages}"   # MODEL: empty = the newest listed haiku; URL: tests point it at a stub
SW_API_MODEL_PIN=claude-haiku-5-5   # the fallback only, when the model listing fails (the newest haiku when this was pinned)
SW_STATE="$SALA_SIGNIN_STATE"   # common.sh's path: lane_out reads it (the rescue)
# the keys of a lane renamed since the state was written (max.seen is now subscription-1.seen): a read falls back to the old key when the new one holds nothing; a write goes to the new key and empties an old one that is still there
_sw_legacy_key() { case "$1" in subscription-1.*) echo "max.${1#*.}";; subscription-2.*) echo "team.${1#*.}";; esac; }
sw_get() { local _v _o; _v=$(_kv_first "$SW_STATE" "$1"); if [ -z "$_v" ]; then _o=$(_sw_legacy_key "$1"); [ -z "$_o" ] || _v=$(_kv_first "$SW_STATE" "$_o"); fi; [ -z "$_v" ] || printf '%s\n' "$_v"; return 0; }
sw_set() { local _o; _kv_set "$SW_STATE" "$1" "$2" || return 1; _o=$(_sw_legacy_key "$1"); [ -z "$_o" ] || [ -z "$(_kv_first "$SW_STATE" "$_o")" ] || _kv_set "$SW_STATE" "$_o" ""; return 0; }
# sw_auth_status <lane> → "<loggedIn 0|1>|<authMethod>|<subscriptionType>|<orgName>" from the CLI, or nothing when it gave no JSON
sw_auth_status() {
    local d out; d=$(lane_dir "$1")
    out=$(env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_CUSTOM_HEADERS -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDE_CONFIG_DIR \
          ${d:+CLAUDE_CONFIG_DIR="$d"} timeout 30 "$SALA_CLAUDE" auth status --json 2>/dev/null </dev/null)
    printf '%s' "$out" | python3 -c '
import json, sys
try: o = json.loads(sys.stdin.read())
except Exception: sys.exit(1)
if not isinstance(o, dict): sys.exit(1)
f = lambda k: str(o.get(k) if o.get(k) is not None else "").replace("|", " ").replace("\n", " ")
print("%s|%s|%s|%s" % ("1" if o.get("loggedIn") else "0", f("authMethod"), f("subscriptionType"), f("orgName")))' 2>/dev/null
}
sw_and() { local o="$1"; shift; while [ $# -gt 1 ]; do o="$o, $1"; shift; done; [ $# = 1 ] && o="$o and $1"; echo "$o"; }   # <lane…> → "Team and api", "Team, api and bedrock"
sw_sub_words() { case "$1" in max) echo "a Max account";; team) echo "a Team account";; pro) echo "a Pro account";; enterprise) echo "an Enterprise account";; *) echo "a '$1' account";; esac; }
sw_org_words() { case "$1" in '') echo "no organization";; *@*) echo "a personal organization";; *) echo "the $1 organization";; esac; }   # never an email in a post
# sw_login <lane> → "ok|<seen>", "wrong|<seen>" or "unknown|<why>" for a login lane, against lane_expect
sw_login() {
    local lane="$1" exp esub eorg st li am sub org seen
    exp=$(lane_expect "$lane"); esub=${exp%%|*}; eorg=${exp#*|}
    st=$(sw_auth_status "$lane") || { echo "unknown|claude auth status gave no answer"; return 0; }
    IFS='|' read -r li am sub org <<< "$st"
    [ "$li" = 1 ] || { echo "wrong|not signed in"; return 0; }
    [ -n "$sub" ] || { echo "wrong|signed in by ${am:-an unknown method}, with no subscription"; return 0; }
    seen=$(sw_sub_words "$sub"); [ -n "$eorg" ] && seen="$seen ($(sw_org_words "$org"))"
    if [ "$sub" = "$esub" ] && { [ -z "$eorg" ] || [ "$org" = "$eorg" ]; }; then echo "ok|$seen"; else echo "wrong|$seen"; fi
}
sw_expected() { local exp esub eorg; exp=$(lane_expect "$1"); esub=${exp%%|*}; eorg=${exp#*|}; printf '%s' "$(sw_sub_words "$esub")"; [ -n "$eorg" ] && printf ' (%s)' "$(sw_org_words "$eorg")"; echo; }
sw_login_fix() {  # <lane> → the fix line of a login lane's alert
    local d; d=$(lane_dir "$1")
    echo "sign the lane in again in the web UI's Shell: \`${d:+CLAUDE_CONFIG_DIR=$d }claude auth login --claudeai\` (open the link it prints, then paste the code back with Shift+Insert) — never /login inside a pane, which re-signs every pane on the lane; to put one pane on another account: \`sala lane <lane> <session>\`"
}
sw_api_wanted() {  # 0 when the api lane is in use here: its key file exists, or a session's row or the default is api or sdk
    [ -e "$SALA_LANE_API_KEY_FILE" ] && return 0
    case "$(lane_default)" in api|sdk) return 0;; esac
    [ -r "$SALA_LANES" ] && awk -F'\t' '$2=="api" || $2=="sdk" {f=1} END {exit !f}' "$SALA_LANES"
}
# sw_api_probe → "nokey" | "net <error>" | "<http status>": one request of max_tokens 1, the key and the workspace id read from
# the lane's files by python3 itself (never on a command line); the model SALA_SIGNIN_API_MODEL, or when it is empty the newest
# haiku GET /v1/models lists (SW_API_MODEL_PIN when the listing fails; a 401/403 from the listing is the answer, no POST made)
sw_api_probe() {
    KF="$SALA_LANE_API_KEY_FILE" WF="$SALA_LANE_API_WORKSPACE_FILE" URL="$SALA_SIGNIN_API_URL" MODEL="$SALA_SIGNIN_API_MODEL" \
        PIN="$SW_API_MODEL_PIN" python3 - <<'PYA' 2>/dev/null
import json, os, sys, urllib.request, urllib.error
from datetime import datetime, timezone
try: key = open(os.environ["KF"]).read().strip()
except OSError: key = ""
if not key: print("nokey"); sys.exit(0)
hdr = {"x-api-key": key, "anthropic-version": "2023-06-01"}
try:
    ws = open(os.environ["WF"]).read().strip() if os.environ.get("WF") else ""
    if ws: hdr["anthropic-workspace-id"] = ws
except OSError: pass
url = os.environ["URL"]; model = os.environ.get("MODEL", "").strip()
if not model:
    model = os.environ["PIN"]
    if url.endswith("/v1/messages"):
        def when(m):  # created_at as an aware datetime, None when missing or unreadable
            try:
                t = datetime.fromisoformat(str(m["created_at"]).replace("Z", "+00:00"))
                return t if t.tzinfo else t.replace(tzinfo=timezone.utc)
            except Exception: return None
        try:
            resp = urllib.request.urlopen(urllib.request.Request(url[:-len("/v1/messages")] + "/v1/models?limit=100", headers=hdr), timeout=20)
            best = None
            for m in json.loads(resp.read().decode()).get("data") or []:
                if not isinstance(m, dict) or not isinstance(m.get("id"), str) or "haiku" not in m["id"]: continue
                t = when(m)
                if t is not None and (best is None or t > best[0]): best = (t, m["id"])   # strict: a tie keeps the first listed
            if best: model = best[1]
        except urllib.error.HTTPError as e:
            if e.code in (401, 403): print(e.code); sys.exit(0)   # the key refused: the same verdict the POST would give
        except Exception: pass   # 429, 5xx, no network, bad JSON: the pin, and the POST decides
body = json.dumps({"model": model, "max_tokens": 1, "messages": [{"role": "user", "content": "hi"}]}).encode()
try: print(urllib.request.urlopen(urllib.request.Request(url, data=body, headers=dict(hdr, **{"content-type": "application/json"}), method="POST"), timeout=20).status)
except urllib.error.HTTPError as e: print(e.code)
except Exception as e: print("net " + type(e).__name__)
PYA
}
# sw_api → "ok|<seen>", "wrong|<seen>", "unknown|<why>" or "same" (the key was asked within SALA_SIGNIN_API_EVERY: nothing new)
sw_api() {
    local now r
    [ -s "$SALA_LANE_API_KEY_FILE" ] && [ -r "$SALA_LANE_API_KEY_FILE" ] || { echo "wrong|no key file at $SALA_LANE_API_KEY_FILE"; return 0; }
    now=$(date +%s); [ $(( now - $(sw_get api.probed | grep . || echo 0) )) -ge "$SALA_SIGNIN_API_EVERY" ] || { echo same; return 0; }
    sw_set api.probed "$now"
    r=$(sw_api_probe); [ -n "$r" ] || r="net NoOutput"
    case "$r" in
        nokey) echo "wrong|no key file at $SALA_LANE_API_KEY_FILE" ;;
        401|403) echo "wrong|the key is refused (HTTP $r)" ;;
        429|5[0-9][0-9]) echo "unknown|the API did not take the request (HTTP $r)" ;;
        net*) echo "unknown|no answer from the API (${r#net })" ;;
        [0-9]*) wlog "signin: api lane: the key was accepted (HTTP $r)"; echo "ok|the key works" ;;
        *) echo "unknown|the probe said '$r'" ;;
    esac
}
# sw_judge <lane> <ok|wrong|unknown> <seen> <expected> <fix>: the episode per lane — a wrong state posted once, until it is right
# or another wrong state; right again posted once when something was posted; unknown changes nothing (logged once per reason)
SW_BROKE=(); SW_FIXED=()
sw_judge() {
    local lane="$1" v="$2" seen="$3" exp="$4" fix="$5" now prev alerted since
    now=$(date +%s)
    if [ "$v" = unknown ]; then
        [ "$(sw_get "$lane.unknown")" = "$seen" ] || { sw_set "$lane.unknown" "$seen"; wlog "signin: $lane lane: $seen — nothing decided from it"; }
        return 0
    fi
    [ -z "$(sw_get "$lane.unknown")" ] || sw_set "$lane.unknown" ""
    prev=$(sw_get "$lane.seen")
    [ "$prev" = "$v: $seen" ] || { sw_set "$lane.seen" "$v: $seen"; sw_set "$lane.since" "$now"; wlog "signin: $lane lane: $v — $seen (expected $exp)"; }
    since=$(sw_get "$lane.since"); alerted=$(sw_get "$lane.alerted")
    case "$lane" in subscription-1|subscription-2)   # the dormant record: a wrong verdict sets it, a right one is the daily look's answer
        if [ "$v" = wrong ]; then ld_login_wrong "$lane" "${since:-$now}" "$seen"; ld_login_looked "$lane"; else ld_login_right "$lane"; fi ;;
    esac
    if [ "$v" = wrong ]; then
        [ "$alerted" = "$seen" ] && return 0
        sw_set "$lane.alerted" "$seen"; SW_BROKE+=("$lane|$exp|$seen|${since:-$now}|$fix")
    elif [ -n "$alerted" ]; then
        sw_set "$lane.alerted" ""; SW_FIXED+=("$lane|$seen|${since:-$now}")
    fi
}
signin_tick() {
    [ "$SALA_SIGNIN_ALERT" = on ] || return 0
    mkdir -p "$SALA_STATE_DIR" 2>/dev/null; touch "$SW_STATE"
    ( flock -n 8 || exit 0; sw_locked ) 8>>"$SW_STATE.lock"
}
sw_locked() {
    local now lane d r e exp seen since fix hl b=() lanes=()
    now=$(date +%s); SW_BROKE=(); SW_FIXED=()
    if [ $(( now - $(sw_get login.checked | grep . || echo 0) )) -ge "$SALA_SIGNIN_EVERY" ]; then
        sw_set login.checked "$now"
        for lane in subscription-1 subscription-2; do
            d=$(lane_dir "$lane")
            if [ -n "$d" ]; then
                [ -d "$d" ] || continue   # not configured
                if ! [ -s "$d/.credentials.json" ]; then
                    # a signed-out team directory is a change: its panes would sit at a login screen
                    sw_judge "$lane" wrong "not signed in" "$(sw_expected "$lane")" "$(sw_login_fix "$lane")"; continue
                fi
            fi
            r=$(sw_login "$lane"); sw_judge "$lane" "${r%%|*}" "${r#*|}" "$(sw_expected "$lane")" "$(sw_login_fix "$lane")"
        done
    fi
    ld_usage_tick   # Team: sala-web's usage check refused (the dormant record, above)
    if sw_api_wanted; then
        r=$(sw_api)
        [ "$r" = same ] || sw_judge api "${r%%|*}" "${r#*|}" "a key the API accepts" "put a working key in $SALA_LANE_API_KEY_FILE (mode 0600); the panes on the api lane take it at their next relaunch"
    fi
    if [ ${#SW_BROKE[@]} -gt 0 ]; then
        for e in "${SW_BROKE[@]}"; do
            IFS='|' read -r lane exp seen since fix <<< "$e"; lanes+=("$(lane_shown "$lane")")
            b+=("$(lane_shown "$lane") lane: expected $exp; seen: $seen, since $(lw_when "$since")" "◦ fix: $fix")
        done
        if [ ${#lanes[@]} = 1 ]; then
            case "$lane|$seen" in api*) hl="The api lane's key does not work";; *"|not signed in") hl="The $(lane_shown "$lane") lane is not signed in";; *) hl="The $(lane_shown "$lane") lane is signed in to the wrong account";; esac
        else hl="Sign-in changed on the $(sw_and "${lanes[@]}") lanes"; fi
        [ "$lane" = api ] && [ ${#lanes[@]} = 1 ] || b+=("every pane on a lane runs on what the lane is signed in to: until the lane is signed in again, its panes are on that account")
        wlog "signin: alert: $hl — $(printf '%s\n' "${SW_BROKE[@]}" | awk -F'|' '{printf "%s%s lane: %s", (NR > 1 ? "; " : ""), $1, $3}')"
        notify "🚨 *$hl*" "${b[@]}"
    fi
    if [ ${#SW_FIXED[@]} -gt 0 ]; then
        b=(); lanes=()
        for e in "${SW_FIXED[@]}"; do IFS='|' read -r lane seen since <<< "$e"; lanes+=("$(lane_shown "$lane")"); b+=("$(lane_shown "$lane") lane: $seen, as expected, since $(lw_when "$since")"); done
        if [ ${#lanes[@]} = 1 ]; then [ "$lane" = api ] && hl="The api lane's key works again" || hl="The $(lane_shown "$lane") lane is signed in correctly again"
        else hl="Signed in correctly again: the $(sw_and "${lanes[@]}") lanes"; fi
        wlog "signin: lifted: $hl"
        notify "✅ *$hl*" "${b[@]}"
    fi
    return 0
}
# STUCK-QUESTION WATCH (posted to Slack): a pane stopped on a TERMINAL-ONLY question (a
# permission dialog, the read-outside-the-working-folder prompt, a numbered menu, the feedback-draft gate: whatever
# pane_prompt reads as a prompt, common.sh SALA_PROMPT_RE) hangs unattended — nobody watches a headless pane, the session's
# inbox is not read while the dialog is up, and sala never types into such a pane. This step reads each pane's last 30
# lines with that same pattern (no Claude turn, no API call) and posts ONCE per session per question: the session, the
# dialog's text (its title, body and question, scrubbed of anything that looks like a secret, ~200 chars) and the
# session's sala-web link (session_url), so the operator can answer it from another device.
#   - THE EPISODE: the dialog's scrubbed text is hashed; the hash, when it was first seen, whether it was posted and how many
#     posts failed are kept per session in SALA_STATE_DIR/stuck.state (key=value, one atomic tmp+mv per write, as the
#     sign-in watch keeps its state). A pane posted once is not posted again while it shows the same question; another
#     question (a different hash) is a new episode and is posted; a pane whose prompt is gone, whose claude is gone or whose
#     session is gone drops its record, so a later stuck episode posts again.
#   - THE CONFIRM WINDOW: a question is posted only once it has been on the screen for SALA_STUCK_CONFIRM seconds (90: the
#     second tick of the 2-min timer). A dialog the operator or a session is answering right then, a relaunch's exit dialog
#     (sala answers it within SALA_EXIT_WAIT), the /feedback panel the drain opens: all gone before the window ends.
#   - A FAILED POST (the notify command exits non-zero): tried again on the next SALA_STUCK_RETRIES ticks, then given up for
#     that episode, each attempt logged; a failure never ends the tick or repeats on every tick. No notify command
#     configured: logged, the episode counts as posted.
#   - SALA_STUCK_POST=off (or 0): nothing read, nothing kept. `sala watch --stuck` runs this step alone; `--stuck --dry-run`
#     prints what it would post now and posts, logs and writes nothing.
#   Every live claude under a tmux pane is read, the Remote Control server's session excepted; a SALA_NO_RELAUNCH session is
#   read too (it is managed outside sala's relaunches, not outside the operator's sight). A `claude -p` under a pane shows no
#   dialog and matches nothing.
#   - THE INSTANT ALERT: the helpers above live in lib/stuck.sh, shared with `salamander hook notify`,
#     the Notification hook that posts the same message about 6 s after a dialog shows (docs/stuck-question-recovery.md). It
#     writes this step's keys (hash, since, posted, tries) under this step's lock, so a question it posted is not posted again here.
: "${SALA_STUCK_POST:=on}"; : "${SALA_STUCK_CONFIRM:=90}"; : "${SALA_STUCK_RETRIES:=2}"
STUCK_ONLY=0; [ "${1:-}" = --stuck ] && STUCK_ONLY=1
SQ_DRY=0; [ "$STUCK_ONLY" = 1 ] && [ "${2:-}" = --dry-run ] && SQ_DRY=1
. "$SALA_ROOT/lib/stuck.sh"   # sq_get/set/drop/key/on, sq_panes, sq_read, sq_send, sq_message (the instant alert, `hook notify`, shares them)
stuck_tick() {
    sq_on || return 0
    [ -d "$SALA_STATE_DIR" ] || mkdir -p "$SALA_STATE_DIR" 2>/dev/null; [ -e "$SQ_STATE" ] || >> "$SQ_STATE"   # (mkdir and touch each tick: two processes)
    ( flock -n 8 || exit 0; sq_locked ) 8>>"$SQ_STATE.lock"
}
sq_locked() {
    local now sess pane pid k r hash sum prev since posted tries seen=" " seenk=" " rc row nm_
    _now_r now
    while IFS='|' read -r sess pane pid; do
        [ -n "$sess" ] && [ "$sess" != "${SALA_RC_SESSION:-}" ] || continue
        case "$seen" in *" $sess "*) continue;; esac; seen="$seen$sess "
        sq_key_r k "$sess"; seenk="$seenk$k "
        if ! r=$(sq_read "$pane") || [ -z "$r" ]; then
            sq_get_r prev "$k.hash"; sq_get_r row "$k.row"; [ -n "$prev" ] || [ -n "$row" ] || continue   # (a row a failed clear left is closed here too)
            [ "$SQ_DRY" = 1 ] && { echo "$sess: no question on its screen any more; its record would be dropped"; continue; }
            sq_settle "$sess" "$k"; wlog "stuck: $sess no longer shows its question — a later one is posted again"; continue
        fi
        hash=${r%%$'\t'*}; sum=${r#*$'\t'}
        sq_get_r prev "$k.hash"
        if [ "$prev" != "$hash" ]; then
            if [ "$SQ_DRY" = 1 ]; then since=$now; posted=""; tries=0
            else sq_set "$k.hash" "$hash"; sq_set "$k.since" "$now"; sq_set "$k.posted" ""; sq_set "$k.tries" 0; since=$now; posted=""; tries=0
                 wlog "stuck: $sess shows a terminal question${prev:+ (another one)}: $sum"; fi
        else sq_get_r since "$k.since"; sq_get_r posted "$k.posted"; sq_get_r tries "$k.tries"; fi
        [ -z "$posted" ] || continue
        [ "${tries:-0}" -le "$SALA_STUCK_RETRIES" ] || continue   # given up for this episode
        [ $(( now - ${since:-$now} )) -ge "$SALA_STUCK_CONFIRM" ] || { [ "$SQ_DRY" = 1 ] && echo "$sess: shows a question for $(( now - ${since:-$now} )) s, posted once it has been there for $SALA_STUCK_CONFIRM s: $sum"; continue; }
        sq_compose "$sess" "$pid" "$sum"   # lib/stuck.sh: the headline and bullets, the same words as the instant alert (`hook notify`)
        if [ "$SQ_DRY" = 1 ]; then echo "would post for $sess:"; sala_post_text "$SQ_HL" "${SQ_B[@]}" | sed 's/^/    /'; continue; fi
        sq_send "$SQ_HL" "${SQ_B[@]}"; rc=$?
        case "$rc" in
            0) sq_set "$k.posted" "$now"; wlog "stuck: posted for $sess: $sum"; sq_row_open "$sess" "$k" "$pane" "$sum" ;;
            3) sq_set "$k.posted" "$now"; wlog "stuck: $sess shows a question, but no notify command is configured (SALA_WATCH_NOTIFY_CMD): $sum"; sq_row_open "$sess" "$k" "$pane" "$sum" ;;
            *) tries=$(( ${tries:-0} + 1 )); sq_set "$k.tries" "$tries"
               if [ "$tries" -le "$SALA_STUCK_RETRIES" ]; then wlog "stuck: the post for $sess failed (exit $rc), try $tries of $(( SALA_STUCK_RETRIES + 1 )) — again at the next tick"
               else wlog "stuck: the post for $sess failed (exit $rc), try $tries of $(( SALA_STUCK_RETRIES + 1 )) — given up for this question"; fi ;;
        esac
    done < <(sq_panes)
    [ "$SQ_DRY" = 1 ] && return 0
    while IFS= read -r k; do   # a session with a record but no live claude pane: its record goes, a later episode posts again
        case "$seenk" in *" $k "*) continue;; esac
        sq_get_r nm_ "$k.sess"; sq_settle "${nm_:-${k#s.}}" "$k"; wlog "stuck: ${k#s.} is gone — its record dropped"
    done < <(got=" "; while IFS= read -r l_; do kk_=${l_%%=*}; case $kk_ in s.*.hash|s.*.row) p_=${kk_%.*}; case "$got" in *" $p_ "*) ;; *) got="$got$p_ "; printf '%s\n' "$p_" ;; esac ;; esac; done < "$SQ_STATE" 2>/dev/null)
    return 0
}
# THE PARKED-QUESTION SWEEP (lib/question.sh): a background run parked on a question resumes only when something asks
# the answer seam for the operator's answer, and nothing else does. Every watch run: one look at the questions directory and, when
# a record is parked or answered (not done), at most once per SALA_QUESTION_SWEEP_EVERY seconds (60; 0/off disables) one
# `sala question sweep` as its own transient unit, sala-auto-qsweep (wd_launch --fixed: systemd refuses a second while one
# runs; RuntimeMaxSec=SALA_QUESTION_SWEEP_TIMEOUT, 1800, bounds it), so a resume that takes minutes never holds the tick. No
# question directory, or none open: nothing else is read and nothing is called (no client call, no unit). The stamp is taken
# before the launch, so a refused launch is tried again only after the interval. Never fails the tick.
: "${SALA_QUESTION_SWEEP_EVERY:=60}"; : "${SALA_QUESTION_SWEEP_TIMEOUT:=1800}"
question_sweep_tick() {
    case "$SALA_QUESTION_SWEEP_EVERY" in ''|0|off|no|false|*[!0-9]*) return 0;; esac
    local d="$SALA_STATE_DIR/questions" stamp="$SALA_STATE_DIR/question-sweep.stamp" now last
    [ -d "$d" ] || return 0
    grep -qsE '"state": "(parked|answered)"' "$d"/*/record.json || return 0
    now=$(date +%s); last=$(cat "$stamp" 2>/dev/null); case "$last" in ''|*[!0-9]*) last=0;; esac
    [ $(( now - last )) -ge "$SALA_QUESTION_SWEEP_EVERY" ] || return 0
    echo "$now" > "$stamp.tmp.$$" && mv -f "$stamp.tmp.$$" "$stamp"
    systemctl --user is-active --quiet sala-auto-qsweep 2>/dev/null && return 0   # the last sweep is still running
    wd_launch --fixed qsweep "$SALA_LOG_DIR/salamander-question.log" question sweep -- -p "RuntimeMaxSec=$SALA_QUESTION_SWEEP_TIMEOUT" "--setenv=PATH=$(dirname "$SALA_CLAUDE"):$PATH" \
        || wlog "questions: systemd-run refused to launch sala-auto-qsweep — tried again in ${SALA_QUESTION_SWEEP_EVERY}s"
    return 0
}
# THE UNIT-GAP PASS (lib/unitjob.py, docs/units.md): a timer of ours (a unit file not shipped under /usr/ or /lib/) with no
# Description=, no X-Model-Lane= or not in git gets one board item (client.py post job-gap open; stackshot moves it by the builder of the repo that owns its script), once per
# timer and gap, and the item is closed (post job-gap clear) and the record goes when the gap does. One python process per run, reading the unit folders: no systemctl, no model. The same pass
# runs from sala-unit-gaps.path when a unit file changes. SALA_UNIT_GAPS=off turns it off. Fail-soft: a failure is a log line, never the tick's.
notice_tick() {   # `sala notice` housekeeping: one python only while a notice or a delivery file is there
    [ -s "$SALA_STATE_DIR/notices.tsv" ] || [ -d "$SALA_STATE_DIR/notices-seen" ] || return 0
    "$SALA_BIN" notice prune >/dev/null 2>&1 || true
}
unit_gaps_tick() {
    case "${SALA_UNIT_GAPS:-on}" in off|no|false|0) return 0;; esac
    local out l
    out=$( [ -n "${SALA_STACKSHOT_DIR+x}" ] && export SALA_STACKSHOT_DIR; [ -n "${SALA_STACKSHOT_CLIENT+x}" ] && export SALA_STACKSHOT_CLIENT
           [ -n "${SALA_JOB_GITHUB+x}" ] && export SALA_JOB_GITHUB; [ -n "${SALA_UNIT_PROJECT_MAP+x}" ] && export SALA_UNIT_PROJECT_MAP; export SALA_STATE_DIR; timeout 30 python3 -I -S "$SALA_ROOT/lib/unitjob.py" check --post --quiet 2>&1 </dev/null ) || wlog "unit-gaps: the pass failed (exit $?)"
    while IFS= read -r l; do [ -n "$l" ] && wlog "unit-gaps: $l"; done <<< "$out"
    return 0
}
# THE FLAG RULE (common.sh, "recycle sets", set_sync): every open Recycle or Revive set (a FLAG) is judged by whether each live pane
# of its scope has relaunched since the flag's time, each tick, so a flag whose last pane came back through another flag's job closes here,
# one post per flag. `--sets --dry-run` prints what it would settle and changes nothing. Each settle is a line in the watch log.
sets_tick() {
    local out l
    if [ "${1:-}" = --dry-run ]; then set_sync --dry-run; [ -e "$SALA_SET_DIR/.reconciled" ] || echo "(first pass on this box: the sets older than $(dur_words "$SALA_SET_QUIET_AFTER") would close without a post)"; return 0; fi
    out=$(set_sync 2>&1) || wlog "sets: the pass failed (exit $?)"
    while IFS= read -r l; do [ -n "$l" ] && wlog "sets: $l"; done <<< "$out"
    return 0
}
# THE BACK AGENTS' LANE RULE (common.sh, "THE BACK AGENTS' LANE RULE"; SALA_BACK_LANE_RULE=on): one pass of back_lane_tick. Its lines go to the watch
# log, a `notice:` line is posted (a step that cannot be taken, a Fable session left where it is); the move itself is a queued `sala op lane … --from
# sala-watch`, whose one notice the operation posts. Runs after the limit and sign-in scans (their state is what it reads) and before the queue
# (a move queued here starts in the same tick). `--back-lanes --dry-run` prints every line, idle ones too, and queues and writes nothing.
back_lane_run() {  # [--dry-run]
    back_lane_on || { [ "${1:-}" = --dry-run ] && echo "idle: SALA_BACK_LANE_RULE is ${SALA_BACK_LANE_RULE:-off}: the rule is off"; return 0; }
    local out l
    out=$(back_lane_tick "$@" 2>&1) || wlog "back lanes: the pass failed (exit $?)"
    while IFS= read -r l; do
        [ -n "$l" ] || continue
        if [ "${1:-}" = --dry-run ]; then echo "$l"; continue; fi
        case "$l" in
            idle:*) ;;   # nothing happened: no line per tick
            notice:*) wlog "back lanes: ${l#notice: }"; notify "⚠️ *Back agents: a lane move did not happen*" "${l#notice: }" ;;
            *) wlog "back lanes: $l" ;;
        esac
    done <<< "$out"
    return 0
}
[ "$BACKLANES_ONLY" = 1 ] && { back_lane_run "${2:-}"; exit 0; }   # `sala watch --back-lanes [--dry-run]`
[ "$WRAPUP_ONLY" = 1 ] && { [ "${2:-}" = --dry-run ] && WRAP_DRY=1; wrapup_tick; exit 0; }   # `sala watch --wrapup [--dry-run]`
[ "$SETS_ONLY" = 1 ] && { sets_tick "${2:-}"; exit 0; }   # `sala watch --sets [--dry-run]`
[ "$CONT_ONLY" = 1 ] && { cont_tick; exit 0; }   # `sala watch --continued`
[ "$UNITGAPS_ONLY" = 1 ] && { unit_gaps_tick; exit 0; }   # `sala watch --unit-gaps`: the unit-gap pass alone
[ "$LIMIT_ONLY" = 1 ] && { limit_tick; ld_post_tick; exit 0; }   # `sala watch --limit`: the usage-limit watch alone
[ "$NET_ONLY" = 1 ] && { net_tick; exit 0; }   # `sala watch --net`: the network-stop wake alone
[ "$SIGNIN_ONLY" = 1 ] && { signin_tick; ld_post_tick; exit 0; }   # `sala watch --signin`: the lane sign-in watch alone
# lane_names_tick: keep $SALA_STATE_DIR/lane-names.json current WITHOUT a process on a tick that finds nothing changed (building it costs a mkdir,
# a mktemp, a cmp and ~30 subshells for the labels). The table can change only when the config is edited (the display names are config settings)
# or when sala's own code changes (a release may change the defaults), so the file is rebuilt when it is missing, when the config file is newer
# than it, or when lib/common.sh (the table's definitions) is newer: three bash tests, no process. A rebuild that finds the same content leaves the
# file alone, so it is touched to mark the check done (otherwise a config edit that changed no name would rebuild on every tick). `sala lane names
# --write` is the explicit write. A failure here never stops a tick.
lane_names_tick() {
    local _f="$SALA_STATE_DIR/lane-names.json"
    if [ -e "$_f" ] && ! [ "$SALA_CONFIG" -nt "$_f" ] && ! [ "$SALA_ROOT/lib/common.sh" -nt "$_f" ]; then return 0; fi
    [ "$(lane_names_write 2>/dev/null)" = unchanged ] && touch -- "$_f" 2>/dev/null
    return 0
}
[ "$STUCK_ONLY" = 1 ] && { stuck_tick; exit 0; }   # `sala watch --stuck [--dry-run]`: the stuck-question watch alone
[ "$OPS_ONLY" = 1 ] && { op_tick; exit 0; }   # `sala watch --ops`: the operation queue alone (lib/op.sh; `sala op` kicks it after a tick already running)
[ "$SETTINGS_ONLY" = 1 ] && { settings_tick; exit 0; }   # `sala watch --settings`: the settings-apply tick alone (lib/settings-apply.sh)
[ "$QUESTIONS_ONLY" = 1 ] && { question_sweep_tick; exit 0; }   # `sala watch --questions`: the parked-question sweep alone
[ "$CHECK_ONLY" = 1 ] || { _claude_panes_r _TICK_PANES; _TICK_PANES_SET=1; }   # one tmux call and one ps pass for the three scans below (limit, net, stuck); nothing acts on a pane in between
[ "$CHECK_ONLY" = 1 ] || limit_tick   # first, before anything that may end this run: it needs no master, no tmux and no idle box
[ "$CHECK_ONLY" = 1 ] || net_tick   # the same: no master; tmux down reads as no panes
[ "$CHECK_ONLY" = 1 ] || signin_tick   # the same: no master, no tmux
[ "$CHECK_ONLY" = 1 ] || ld_post_tick   # the same: the one post of a dormant lane's episode (the dormant record's signals)
[ "$CHECK_ONLY" = 1 ] || back_lane_run   # the same: the back agents' lane rule (off unless SALA_BACK_LANE_RULE=on); reads the limit and quota state just written, queues before the queue runs
[ "$CHECK_ONLY" = 1 ] || lane_names_tick   # the same: lane-names.json (stackshot reads it); a tick that finds nothing changed starts no process for it
[ "$CHECK_ONLY" = 1 ] || stuck_tick   # the same: no master; tmux down reads as no panes
unset _TICK_PANES_SET _TICK_PANES   # what follows may relaunch panes: it reads them afresh
[ "$CHECK_ONLY" = 1 ] || question_sweep_tick   # the same: no master, no tmux; the sweep is its own unit
[ "$CHECK_ONLY" = 1 ] || settings_tick   # the same: no master, no tmux; a run it starts is its own unit, so nothing below waits on it
[ "$CHECK_ONLY" = 1 ] || unit_gaps_tick   # the same: file reads and at most three job-gap opens and three clears
# THE OPERATION QUEUE (lib/op.sh): the oldest queued operation starts as its own sala-op-<id> unit, one at a time,
# master or no master; a runner that ended without a result is settled. One started here counts as this run's automatic
# launch (OP_LAUNCHED → AUTO_LAUNCHED below), so no auto-update, auto-relaunch or auto-recycle starts beside it in the same run.
OP_LAUNCHED=0; [ "$CHECK_ONLY" = 1 ] || op_tick
# NO MASTER (the header): the tick runs on without checks 2–4; the post-boot report goes to Slack. Two readings of an unset
# SALA_MASTER: never had one, or unset on purpose (`salamander master --unset` leaves master_unset in the state): quiet.
# HAD one (state remembers it) and no such record: the config was lost, truncated or edited — say so out loud, once a
# day, fail --check and end the tick, as before. Nothing is healed from memory: the name is the operator's config, not the
# watchdog's to reinvent.
NO_MASTER=0
if [ -z "${SALA_MASTER:-}" ]; then
    NO_MASTER=1
    known=$(st_get master); [ -n "$known" ] || known=$(st_get uuid)
    if [ -n "$known" ] && [ -z "$(st_get master_unset)" ]; then
        msg="SALA_MASTER is unset but this box had a master (${known}) — config $SALA_CONFIG lost or truncated? restore it: diff against $HOME/.claude/salamander-config.last-good; meant to have none? salamander master --unset records that; the watchdog is doing nothing until then"
        echo "⚠ $msg"; [ "$CHECK_ONLY" = 1 ] && exit 1
        last=$(st_get last_config_lost); now=$(date +%s)
        if [ -z "$last" ] || [ $((now - last)) -ge 86400 ]; then st_set last_config_lost "$now"; notify "🚨 *sala's config lost its master*" "SALA_MASTER is unset, but this box had one ($known)" "the watchdog does nothing until it is back" "restore it from ~/.claude/salamander-config.last-good, or run provision; meant to have none: salamander master --unset" "Details: $SALA_CONFIG"; else wlog "config lost (notified $(( (now - last) / 60 )) min ago): $msg"; fi
        exit 1
    fi
else
    st_set master "$SALA_MASTER"
fi
finding() { echo "$*"; [ "$CHECK_ONLY" = 1 ] && exit 1; return 0; }
# heal <kind> <message> <cmd…> — one action per run, cooldown per kind; the run ends after it
heal() {
    local kind="$1" msg="$2"; shift 2
    local last now; last=$(st_get "last_$kind"); now=$(date +%s)
    if [ -n "$last" ] && [ $((now - ${last:-0})) -lt "$SALA_WATCH_COOLDOWN" ]; then
        wlog "SKIP ($kind within cooldown): $msg"; exit 0
    fi
    st_set "last_$kind" "$now"; wlog "HEAL ($kind): $msg → $*"
    local what; case "$kind" in server) what="the tmux server";; session) what="the master's tmux session";; claude) what="the master's Claude";; bridge) what="the master's Remote Control link";; *) what="$kind";; esac
    if "$@"; then notify "🩹 *Watchdog restored $what*" "$msg"; else notify "🚨 *Watchdog could not restore $what*" "$msg" "Details: $WLOG"; fi
    exit 0
}
export SALA_LOCK_WHO="${SALA_LOCK_WHO:-watch}"   # the holder line of a recycle lock watch's own revive takes
busy_elsewhere() {  # a restore or a revive in flight owns the panes right now
    recycle_locked && return 0                      # a relaunch driver holds the recycle lock (common.sh); the pgrep lines back it up
    # pgrep_mine (common.sh): only this instance's processes, never another HOME's sala on the box
    pgrep_mine 'tmux-resurrect/scripts/[r]estore.sh' >/dev/null && return 0
    local ps_ l_ re1='--(retry-worker|self-worker|save-map)|pgrep' re2='--(retry-worker|dry-run)|pgrep'   # (the two grep -v filters are the shell's own: a line that is none of the excluded kinds counts)
    ps_=$(pgrep_mine 'bin/(sala|salamander) revive'); while IFS= read -r l_; do [ -n "$l_" ] && ! [[ $l_ =~ $re1 ]] && return 0; done <<< "$ps_"
    ps_=$(pgrep_mine 'bin/(sala|salamander) rename '); while IFS= read -r l_; do [ -n "$l_" ] && ! [[ $l_ =~ $re2 ]] && return 0; done <<< "$ps_"   # mid-rename the master's name is in flux
    return 1
}

# post-boot report helpers (check 5). State: boot_announced = the boot id last reported, boot_kernel = its kernel.
BOOT=$(boot_id 2>/dev/null); BOOT_AGE=$(( $(date +%s) - $(boot_epoch 2>/dev/null || date +%s) ))
if [ "$CHECK_ONLY" = 0 ] && [ -n "$BOOT" ] && [ -z "$(st_get boot_announced)" ]; then
    st_set boot_announced "$BOOT"; st_set boot_kernel "$(uname -r)"        # first run on this install: seed, report from the next boot on
fi
boot_pending() { [ "$CHECK_ONLY" = 0 ] && [ -n "$BOOT" ] && [ "$(st_get boot_announced)" != "$BOOT" ]; }
boot_done() { st_set boot_announced "$BOOT"; st_set boot_kernel "$(uname -r)"; }
boot_report() {  # the report text; $1 = how it is delivered ("inbox" | "notify")
    local rec="" k prev when
    [ "$(head -1 "$SALA_BOOT_REC" 2>/dev/null)" = "$BOOT" ] && rec=$(tail -n +2 "$SALA_BOOT_REC")
    k=$(uname -r); prev=$(st_get boot_kernel)
    echo "[sala boot] $(hostname) came back up at $(local_human "$(boot_epoch)") on kernel $k$( [ -n "$prev" ] && [ "$prev" != "$k" ] && echo " (was $prev)")."
    if [ -n "$rec" ]; then
        when=$(printf '%s\n' "$rec" | head -1)
        echo "Revive finished at $(local_human "$when"): $(printf '%s\n' "$rec" | sed -n 2p)"
        printf '%s\n' "$rec" | sed -n 's/^skipped: /  - /p'
        printf '%s\n' "$rec" | sed -n 's/^served: .*⤷ served /  ⤷ Remote Control served session /p'
    else
        echo "Revive left no summary within $((SALA_BOOT_GRACE/60)) min of boot — the resurrect restore or its post-restore hook may not have run; check the panes."
    fi
    # THE NETWORK STOP: the revive line above counts the panes stopped when revive finished; panes whose first turn
    # ends on the error later are named here, as they are when the report is made
    local ns; ns=$(lw_panes 2>/dev/null | net_scan 2>/dev/null | awk '{printf "%s%s", (n++ ? ", " : ""), $2}')
    [ -n "$ns" ] && echo "Stopped on a network error right now: $ns.$([ "$SALA_NET_WAKE" = on ] && echo " sala sends each one message once the network is back.")"
    [ "$(head -1 "$SALA_LOG_DIR/salamander-reboot.result" 2>/dev/null)" = "$BOOT" ] && tail -n +2 "$SALA_LOG_DIR/salamander-reboot.result"
    # a clean reboot recreates what did not come back on its own (lib/reboot.sh); after any other boot the gap is named here
    local miss; miss=$(ledger_missing | wc -l | tr -d ' ')
    [ "${miss:-0}" -gt 0 ] && echo "$miss session(s) in the pane map have no tmux session: \`sala restore --missing\` recreates them in their directories and resumes their conversations."
    [ "$1" = inbox ] || return 0
    if [ -n "$SALA_BOOT_AUDIT" ]; then echo "Automatic salamander message, once per boot (not ${SALA_OWNER_NAME}'s words). Run the post-boot audit and report in your own pane: $SALA_BOOT_AUDIT"
    else echo "Automatic salamander message, once per boot (not ${SALA_OWNER_NAME}'s words). Check the box and report in your own pane."; fi
}
# a boot whose master never came back: the deadline passes with no live claude in its pane → say it out of band
if [ "$NO_MASTER" = 0 ] && boot_pending && [ "$BOOT_AGE" -ge "$SALA_BOOT_DEADLINE" ]; then
    mp=$(tmux list-panes -t "$(tmux_win_t "$SALA_MASTER")" -F '#{pane_id}' 2>/dev/null | head -1)
    if [ -z "$mp" ] || [ -z "$(claude_pid_under "$(tmux display -p -t "$mp" '#{pane_pid}')" 2>/dev/null)" ]; then
        boot_done; mapfile -t rb < <(report_bullets); notify "⚠️ *$(hostname) came back up — $SALA_MASTER is not live*" "nobody got the post-boot report $((BOOT_AGE/60)) min after boot; here it is:" "${rb[@]}"
    fi
fi

# 1. tmux server
if ! tmux has-session 2>/dev/null; then
    finding "tmux server is down"
    if systemctl --user cat tmux.service >/dev/null 2>&1; then heal server "tmux server down" systemctl --user start tmux.service
    elif [ "$NO_MASTER" = 0 ]; then heal server "tmux server down (no tmux.service)" tmux new-session -d -s "$SALA_MASTER" -c "$(master_dir)"
    else wlog "tmux server down: no tmux.service to start, and no master session to start a bare server for — nothing done"; exit 0; fi
fi
busy_elsewhere && { [ "$CHECK_ONLY" = 1 ] || bare_state_reset; wlog "skip: a resurrect restore or a salamander revive is running"; exit 0; }   # (the bare-pane clocks start over: lib/barepane.sh)
# A STALE FREEZE: the roster freeze a recycle or reboot holds on the pane map (common.sh, ledger_freeze)
# is lifted by the run that took it; a driver that died (a kill, a crash) or a boot half that never ran leaves it, and
# every spawn, rename, retire and adopt is refused meanwhile — so a freeze whose owner is dead on this boot, a recycle's
# from an earlier boot, or one older than 3 h is cleared here, with a report, and the follows deferred under it apply.
if [ "$CHECK_ONLY" = 0 ] && ledger_freeze_stale; then
    fl=$(ledger_freeze_line); ledger_unfreeze "stale, cleared by watch"
    wlog "stale pane-map freeze cleared: $fl"
    notify "⚠️ *Pane-map freeze cleared*" "the map was $fl" "its owner is gone, so sala lifted it; spawn, rename, retire and adopt work again" "if a recycle or reboot died, check its log" "Details: $SALA_LEDGER_LOG"
fi
# NO WHOLE-BOX IDLE WAIT (a recycle cued at once skips busy panes and retries later anyway, so sala's recycle guard
# mechanisms are sufficient): the two automatic relaunches below used to
# start only once no Claude pane on the box had written its transcript for SALA_AUTO_IDLE (10 min) and none was busy
# (box_idle) — a state a busy box rarely reaches, so relaunches would wait for hours. They are cued as soon as they are due.
# What protects a working session is the recycle's own per-pane guard, unchanged: a pane mid-turn, inside the idle settle,
# not yet at its ready marker or holding background work (the busy hooks' record, is_idle_reason) is skipped (rc 2) and its
# retry worker relaunches it once idle; background work goes to the deferred list. SALA_AUTO_IDLE, SALA_AUTO_UPDATE_IDLE and
# SALA_BUSY_STALE are no longer read. What still keeps two automatic relaunches apart: one launch per run (AUTO_LAUNCHED),
# the recycle lock, the auto-recycle's hourly limit and its 10-min cache of the board's answer.
# the CLI updates itself, with no idle wait (there is no benefit in waiting while a claude runs the
# update). Once npm has a newer Claude Code (asked at most every
# 10 min), every box behind it is updated AT ONCE, in one `update <hosts…> --auto` unit and so one post:
#  - each fleet box that answers ssh (the heartbeat store: its version + fleet_ssh); a sleeping box is picked up the next
#    time the heartbeat sees it awake;
#  - this box: its CLI only (--no-recycle) — running panes keep their version, a mixed state that is fine until the
#    relaunch below (auto_relaunch), cued on the next run once the launcher has moved. Launching it counts as this run's automatic
#    launch (AUTO_LAUNCHED), so no recycle — whose --update runs `claude update` too — starts beside it in the same run.
# Each host is tried once per version, never downgraded. The try is recorded before the unit launches (so a slow unit is not
# launched twice); a box the unit then finds offline — the heartbeat saw it awake, its own 8 s probe a minute later did not
# — was not tried: update.sh --auto (auto_untry) takes the marker out again, and this function launches the box
# again on a later run once the heartbeat sees it awake. A real attempt, failed or not, keeps its marker.
: "${SALA_AUTO_UPDATE:=on}"
AUTO_LAUNCHED=${OP_LAUNCHED:-0}   # one automatic launch on this box per run: one launched here (an operation of the queue included) leaves the others for a later run
au_launch() {  # <unit tag> <update args…>
    local tag="$1"; shift
    wd_launch "update-$tag" "$SALA_LOG_DIR/salamander-update.log" update "$@" --auto \
        || notify "🚨 *CLI update could not start*" "update of $* was due, but systemd-run refused to launch it" "Details: $WLOG"
}
auto_update() {
    [ "$SALA_AUTO_UPDATE" = on ] || return 0
    local now last cur latest due h v me rel norc=""
    now=$(date +%s); last=$(st_get auto_update_checked); [ $((now - ${last:-0})) -ge 600 ] || return 0
    st_set auto_update_checked "$now"
    latest=$(curl -s --max-time 10 https://registry.npmjs.org/@anthropic-ai/claude-code/latest | python3 -c 'import json,sys;print(json.load(sys.stdin).get("version",""))' 2>/dev/null)
    [ -n "$latest" ] || return 0
    newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$2" ]; }   # $2 newer than $1
    due=""
    while IFS='|' read -r h v; do
        [ -n "$h" ] && [ -n "$v" ] && newer "$v" "$latest" && [ "$(st_get "auto_update_tried_$h")" != "$latest" ] || continue
        st_set "auto_update_tried_$h" "$latest"; due="$due $h"
    done < <(fleet_awake)
    me=$(hostname); cur=$(claude_ver)
    if [ -n "$cur" ] && newer "$cur" "$latest" && [ "$(st_get auto_update_tried)" != "$latest" ]; then
        st_set auto_update_tried "$latest"; due="$due $me"; norc=--no-recycle; AUTO_LAUNCHED=1
    fi
    # the first run for a release reports every machine (--release); a catch-up run for a box that woke later reports only
    # that box
    rel=""; [ "$(st_get auto_update_release)" = "$latest" ] || { st_set auto_update_release "$latest"; rel=--release; }
    [ -n "$due" ] || return 0
    wlog "auto-update: $latest → now:$due${rel:+ (release run)}${norc:+ — this box ($cur) its CLI only; its panes relaunch at the next run}"
    au_launch cli $due $rel $norc
}
# THE RELAUNCH HALF: panes that run an older version than the
# installed CLI — after the update above, or any other that moved the launcher — are relaunched: `recycle` without
# --force, which moves only those panes (the same comparison as update.sh's: stale_panes), as its own unit holding the
# recycle lock as auto-update. One try per installed version (auto_update_relaunched); a pane that recycle leaves behind is
# its retry worker's or the deferred list's. Never beside another automatic launch in the same run, during a reboot, with
# the pane map frozen or while a relaunch holds the lock. The recycle's own post ("Recycle done · N panes on <version>")
# is the post; the update's post already said the panes relaunch, each once it is idle.
au_say() {  # <key> <message>: a waiting line, logged when it changes rather than on every run
    [ "$(st_get auto_update_said)" = "$1" ] && return 0
    st_set auto_update_said "$1"; wlog "auto-update: $2"
}
auto_relaunch() {
    [ "$SALA_AUTO_UPDATE" = on ] || return 0
    local cur stale n what gl
    cur=$(claude_ver)
    case "$cur" in [0-9]*) ;; *) return 0;; esac   # a launcher that is not a versions/<ver> link tells nothing
    [ "$(st_get auto_update_relaunched)" != "$cur" ] || return 0
    stale=$(stale_panes "$cur"); n=$(_nlines "$stale")
    [ "$n" -gt 0 ] || return 0
    what="$n pane$([ "$n" -gt 1 ] && echo s) on an older CLI than the installed $cur ($(echo $stale | sed 's/ /, /g'))"
    gl=$(recycle_job_gate update "update:$cur") || { au_say gather "$what — $gl"; gather_note "$gl"; return 0; }   # the job's gate
    [ "$AUTO_LAUNCHED" = 0 ] || { au_say launched "$what — this run launched another update or relaunch; the next run looks again"; return 0; }
    command -v systemd-run >/dev/null 2>&1 || { au_say nosystemd "$what, but there is no systemd-run on this box to relaunch them"; return 0; }
    shutting_down && { au_say reboot "$what, but a reboot is under way"; return 0; }
    ledger_frozen && { au_say frozen "$what, but the pane map is $(ledger_freeze_line)"; return 0; }
    recycle_locked && { au_say locked "$what, but $(recycle_holder_line)"; return 0; }
    st_set auto_update_relaunched "$cur"; st_del auto_update_said
    wlog "auto-update: relaunching $what — \`recycle\` (those panes only; a busy one is skipped and retried once idle)"
    if wd_launch relaunch "$SALA_LOG_DIR/salamander-revive.log" recycle -- --setenv=SALA_LOCK_WHO=auto-update --setenv=SALA_LOCK_WAIT=600 --setenv=SALA_RELAUNCH_KIND=update; then   # KIND: what a waiting pane is told
        AUTO_LAUNCHED=1; gather_clear
    else
        notify "🚨 *Auto-relaunch could not start*" "$what" "systemd-run refused to launch it; they move at the next recycle" "Details: $WLOG"
    fi
}
[ "$CHECK_ONLY" = 1 ] || auto_update
[ "$CHECK_ONLY" = 1 ] || auto_relaunch
[ "$CHECK_ONLY" = 1 ] || provision_sets_tick
# AUTO-RECYCLE: what used to wait for a cue to the master — a relaunch so every
# pane re-reads its connectors, CLAUDE.md, skills and settings — runs on its own as soon as it is due (no whole-box idle
# wait: above), when
#  - board items on this box wait for a recycle: SALA_RECYCLE_WANTED_CMD prints a count, then optionally ids (sh -c,
#    20 s timeout, asked at most every 10 min and cached here; empty, non-numeric output or a non-zero exit = 0). Ids an
#    earlier auto-recycle already served do not count again, so an item whose flag the board did not clear cannot recycle
#    the box every hour. SERVED IDS DROP WHEN THE BOARD CLEARS THEM: a guard that kept every served id would predate the
#    board clearing an item's flag itself after a recycle, and kept a served id forever, so one item, flagged again
#    for a new change two hours after its auto-recycle, wait for the operator's cue. Now the ids the post-recycle command
#    reports cleared (common.sh, post_recycle_hook: SALA_RECYCLE_CLEARED_DIR) leave the served ids at the next run
#    (ar_cleared), and the board's cached answer is asked afresh, so a later flag on the same item counts again; a report
#    that cannot be parsed or a command that failed leaves them as they are. A token may also be `<id>@<epoch>` (the
#    flag's set time): a re-flag is then a new token even if no report came; the posts and the log show the bare id;
#    a token is `<id>[@<epoch>][~<ref>]`, the ref the change the flag waits for (below);
#  - or a session asked: `sala recycle --when-idle "<reason>"` (lib/recycle-request.sh) left a marker; 24 h expiry.
# TWO GUARDS, for a board flag and a request alike, each logging one line saying why nothing was recycled. Why: a flag served at
# once for a change whose pull request has not merged yet, while every pane was relaunched minutes before, would relaunch every
# pane a second time on the same CLI.
#  - THE CHANGE IS NOT LIVE: a flag that names its change (`--change REF` on a request; `~REF` on a board token, which stackshot's
#    recycle-wanted does not print yet: docs/stackshot-contracts.md, interface 5) is not served while the change is missing from the
#    production checkout's HEAD (rr_change_state, lib/recycle-request.sh): not merged, or merged and not deployed. It is held up to
#    SALA_RECYCLE_REF_WAIT (24 h) after the flag, then judged as a flag with no change. A reference sala cannot check counts as live.
#  - EVERY PANE IS NEWER THAN THE FLAG: when every live Claude pane started after the flag's time (and after its change landed, with
#    SALA_RECYCLE_REF_SLACK for the deploy), nothing is left for a recycle to do: a request is dropped, a board flag is reported
#    served to the board (the post-recycle command, with the flag's time) and nothing is launched. A token with no epoch is timed
#    by when watch first saw the board list it (an upper bound of the flag's time, so the guard never skips a flag it cannot prove served).
# Then the recycle the master's cue would run ("recycle claude" → `recycle --update --force`), once, as its own unit; the
# request markers it served are cleared and one post says what triggered it. Never while a recycle, revive, restore or
# rename runs (busy_elsewhere ended this run above), during a reboot or with the pane map frozen; at most once an hour.
: "${SALA_AUTO_RECYCLE:=on}"; : "${SALA_RECYCLE_WANTED_CMD:=}"
. "$SALA_ROOT/lib/recycle-request.sh"
ar_say() {  # <key> <message>: a waiting line, logged when it changes rather than on every run
    [ "$(st_get auto_recycle_said)" = "$1" ] && return 0
    st_set auto_recycle_said "$1"; wlog "auto-recycle: $2"
}
recycle_wanted() {  # → "<count>|<ids>" from the board, cached for 10 min
    [ -n "$SALA_RECYCLE_WANTED_CMD" ] || { echo "0|"; return; }
    local now last out n ids
    now=$(date +%s); last=$(st_get recycle_wanted_at)
    if [ $((now - ${last:-0})) -lt 600 ]; then echo "$(st_get recycle_wanted_n)|$(st_get recycle_wanted_ids)"; return; fi
    out=$(timeout 20 sh -c "$SALA_RECYCLE_WANTED_CMD" 2>/dev/null </dev/null) || out=""
    n=$(printf '%s\n' "$out" | awk 'NF {print $1; exit}'); case "$n" in ''|*[!0-9]*) n=0; out="";; esac
    ids=$(printf '%s\n' "$out" | awk 'NF && !d {$1=""; d=1} {print}' | tr -s ' \t\n,' ' ' | sed 's/^ //; s/ $//' | cut -c1-400)
    n=$((10#$n))
    st_set recycle_wanted_at "$now"; st_set recycle_wanted_n "$n"; st_set recycle_wanted_ids "$ids"
    echo "$n|$ids"
}
ar_shown() { local t o=""; for t in $1; do case "$t" in g[0-9]*) o="$o board#${t#g}";; *) o="$o $t";; esac; done; echo "${o# }"; }   # <ids> → the ids as the board shows them: store id gN reads board#N (the post's link pass then links it)
ar_ids() { local t o=""; for t in $1; do o="$o ${t%%[@~]*}"; done; echo "${o# }"; }   # <tokens> → the ids without their @<epoch> and ~<ref>
# A TOKEN is <id>[@<epoch>][~<ref>]: the epoch is the flag's time, the ref the change the flag waits for (a commit sha or pr<N>, lib/recycle-request.sh).
ar_tok_at() { local t=${1%%~*}; case "$t" in *@*) echo "${t#*@}";; esac; return 0; }
ar_tok_ref() { case "$1" in *~*) echo "${1#*~}";; esac; return 0; }
ar_first_seen() {  # <id> → the epoch watch first saw the board list it: an upper bound of the flag's time, for a token that carries none
    local id="$1" cur kv now; cur=$(st_get auto_recycle_first_seen)
    for kv in $cur; do [ "${kv%%:*}" = "$id" ] && { echo "${kv#*:}"; return 0; }; done
    _now_r now; st_set auto_recycle_first_seen "${cur:+$cur }$id:$now"; echo "$now"
}
ar_seen_prune() {  # <ids on the board now> → first-seen times of ids the board no longer lists are dropped
    local cur kv keep="" id; cur=$(st_get auto_recycle_first_seen); [ -n "$cur" ] || return 0
    for kv in $cur; do id=${kv%%:*}; case " $(ar_ids "$1") " in *" $id "*) keep="$keep $kv";; esac; done
    keep=${keep# }; [ "$keep" = "$cur" ] || { if [ -n "$keep" ]; then st_set auto_recycle_first_seen "$keep"; else st_del auto_recycle_first_seen; fi; }
}
# ar_panes_after <epoch> → 0 and "<panes> <oldest start epoch>" when this box has live Claude panes and every one of them started
# after <epoch> (the whole second, as the flag rule does: common.sh, _set_sync); 1 otherwise. A shell session, a pane managed outside
# sala and a pane with no claude to read right now (between /exit and its resume) do not count either way.
ar_panes_after() {
    local t0="$1" s st sa ver n=0 oldest=""
    while IFS= read -r s; do
        [ -n "$s" ] || continue; no_relaunch "$s" && continue
        read -r st sa ver <<< "$(_set_pane_read "$s")"; [ "$st" = live ] || continue
        [ "$sa" -ge $(( (t0 + 1) * 1000 )) ] || return 1
        n=$((n + 1)); [ -z "$oldest" ] || [ $((sa / 1000)) -lt "$oldest" ] && oldest=$((sa / 1000))
    done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)
    [ "$n" -gt 0 ] || return 1
    echo "$n $oldest"
}
# ar_judge <flag epoch> <change ref or empty> → one line: `go` (recycle for it), `hold <why>` (its change is not in the checkout yet),
# or `covered <panes> <oldest start>` (every live pane started after the flag, and after its change landed + SALA_RECYCLE_REF_SLACK).
ar_judge() {
    local at="$1" ref="$2" since="$1" st r now; _now_r now
    case "$at" in ''|*[!0-9]*|0) echo go; return 0;; esac
    if [ -n "$ref" ] && [ "${SALA_RECYCLE_REF_WAIT:-0}" -gt 0 ] 2>/dev/null && [ $((now - at)) -lt "$SALA_RECYCLE_REF_WAIT" ]; then
        st=$(rr_change_state "$ref")
        case "${st%% *}" in
            pending) echo "hold $ref is not in the checkout yet (HEAD ${st#* })"; return 0;;
            live) [ $(( ${st#* } + SALA_RECYCLE_REF_SLACK )) -gt "$since" ] && since=$(( ${st#* } + SALA_RECYCLE_REF_SLACK ));;
        esac
    fi
    if r=$(ar_panes_after "$since"); then echo "covered $r"; else echo go; fi
}
ar_cleared() {  # the ids the board reported cleared after a recycle (post_recycle_hook's files) leave the served ids
    local f cl="" t s kept="" gone=""
    for f in "$SALA_RECYCLE_CLEARED_DIR"/*.ids; do
        [ -f "$f" ] || continue; cl="$cl $(tr -c 'A-Za-z0-9#@._-' ' ' < "$f")"; rm -f "$f"
    done
    cl=" $(ar_ids "$cl") "; [ -n "${cl// /}" ] || return 0
    s=$(st_get auto_recycle_served_ids); [ -n "$s" ] || return 0
    for t in $s; do case "$cl" in *" ${t%%[@~]*} "*) gone="$gone ${t%%[@~]*}";; *) kept="$kept $t";; esac; done
    [ -n "$gone" ] || return 0
    st_set auto_recycle_served_ids "${kept# }"; st_set recycle_wanted_at 0   # the board's cached answer may predate the clear
    wlog "auto-recycle: the board no longer holds$gone for a recycle — a later flag on them counts again"
}
auto_recycle() {
    ar_cleared   # also when off: the files are read and removed either way
    [ "$SALA_AUTO_RECYCLE" = on ] || return 0
    local e now bw n ids served fresh="" i reqs=() rq_by rq_why board="" bullets=() last gkeys=() gl
    local cand at ref v kept=() held=() heldtok=" " cov=() covtok="" covat=0 covinfo="" nfresh=0 sv=""
    while IFS= read -r e; do wlog "auto-recycle: a request expired after 24 h — $e"; done < <(rr_expire)
    mapfile -t reqs < <(rr_files)
    bw=$(recycle_wanted); n=${bw%%|*}; ids=${bw#*|}
    ar_seen_prune "$ids"
    if [ "${n:-0}" -gt 0 ] && [ -n "$ids" ]; then   # with ids: only those no earlier auto-recycle served
        served=" $(st_get auto_recycle_served_ids) "
        for i in $ids; do case "$served" in *" $i "*) ;; *) fresh="$fresh $i";; esac; done; fresh=${fresh# }
        # THE TWO GUARDS, for each flag not served yet: its change is not in the checkout yet (hold), or every pane
        # was relaunched after the flag (covered: the board is told, as a recycle would have, and nothing is recycled)
        cand=$fresh; fresh=""
        for i in $cand; do
            at=$(ar_tok_at "$i"); ref=$(ar_tok_ref "$i"); case "$at" in ''|*[!0-9]*) at=$(ar_first_seen "${i%%[@~]*}");; esac
            v=$(ar_judge "$at" "$ref")
            case "$v" in
                hold*) held+=("$(ar_shown "${i%%[@~]*}"): ${v#hold }"); heldtok="$heldtok$i ";;
                covered*) cov+=("$(ar_shown "${i%%[@~]*}")"); covtok="$covtok $i"; covinfo=${v#covered }; [ "$at" -gt "$covat" ] && covat=$at;;
                *) fresh="$fresh $i"; nfresh=$((nfresh + 1));;
            esac
        done; fresh=${fresh# }
        [ -n "$fresh" ] && board="$nfresh board item$([ "$nfresh" -gt 1 ] && echo s) waited for a recycle ($(ar_shown "$(ar_ids "$fresh")" | sed 's/ /, /g'))"
        if [ ${#cov[@]} -gt 0 ]; then
            wlog "auto-recycle: skipped ${cov[*]} — every pane (${covinfo%% *}) was relaunched after the flag was raised (the oldest launch $(local_clock "${covinfo#* }")); no recycle needed, the board is told its flag is served"
            sv="$(st_get auto_recycle_served_ids)$covtok"; st_set auto_recycle_served_ids "${sv# }"   # (the hook below reports the clear back only while served ids are held: post_recycle_hook)
            post_recycle_hook "$SALA_LOG_DIR/salamander-revive.log" recycle "$covat"
        fi
    elif [ "${n:-0}" -gt 0 ]; then board="$n board item$([ "$n" -gt 1 ] && echo s) waited for a recycle"; fi
    # a request: the same two guards; its marker is read for the change it waits for (the 4th field)
    for e in ${reqs[@]+"${reqs[@]}"}; do
        IFS=$'\t' read -r at rq_by rq_why ref < "$e" || true
        v=$(ar_judge "$at" "$ref")
        case "$v" in
            hold*) held+=("request from ${rq_by:-?}: ${v#hold }");;
            covered*) rm -f "$e"; wlog "auto-recycle: skipped the request from ${rq_by:-?} (${rq_why:-no reason given}) — every pane (${v#covered }) was relaunched after it was asked; dropped, no recycle needed";;
            *) kept+=("$e");;
        esac
    done; reqs=(${kept[@]+"${kept[@]}"})
    if [ ${#held[@]} -gt 0 ]; then   # one line when it changes, or with the launch below when other flags go
        sv="skipped — waiting for the change each flag names to be in the production checkout: $(printf '%s; ' "${held[@]}" | sed 's/; $//')"
        if [ -z "$board" ] && [ ${#reqs[@]} -eq 0 ]; then ar_say "hold:$(printf '%s' "${held[*]}" | cksum | cut -d' ' -f1)" "$sv"; else wlog "auto-recycle: $sv"; fi
    fi
    if [ -z "$board" ] && [ ${#reqs[@]} -eq 0 ]; then
        [ "${n:-0}" -gt 0 ] && [ ${#held[@]} -eq 0 ] && [ ${#cov[@]} -eq 0 ] && ar_say served "$n board item(s) wait for a recycle, but an earlier auto-recycle already served them ($(ar_ids "$ids")) — waiting for their owners to close them"
        return 0
    fi
    # the job's gate: the flags pending now, by key; an unfinished job gathers them before it resets
    for e in ${reqs[@]+"${reqs[@]}"}; do gkeys+=("req:$(basename "$e" .req)"); done
    if [ -n "$fresh" ]; then for i in $fresh; do gkeys+=("board:${i%%[@~]*}"); done; elif [ -n "$board" ]; then gkeys+=("board:$n"); fi
    gl=$(recycle_job_gate auto "${gkeys[@]}") || { ar_say gather "$gl"; gather_note "$gl"; return 0; }
    [ "$AUTO_LAUNCHED" = 0 ] || { wlog "auto-recycle: due, but this run launched the CLI update or a relaunch; the next run looks again"; return 0; }
    command -v systemd-run >/dev/null 2>&1 || { ar_say nosystemd "due, but there is no systemd-run on this box to launch it"; return 0; }
    shutting_down && { ar_say reboot "due, but a reboot is under way"; return 0; }
    ledger_frozen && { ar_say frozen "due, but the pane map is $(ledger_freeze_line)"; return 0; }
    recycle_locked && { ar_say locked "due, but $(recycle_holder_line)"; return 0; }
    now=$(date +%s); last=$(st_get auto_recycle_at)
    if [ -n "$last" ] && [ $((now - last)) -lt 3600 ]; then ar_say hourly "due, but the last auto-recycle was $(( (now - last) / 60 )) min ago (at most one an hour)"; return 0; fi
    # the trigger, in the post's words
    [ -n "$board" ] && bullets+=("$board")
    for e in ${reqs[@]+"${reqs[@]}"}; do IFS=$'\t' read -r _ rq_by rq_why _ < "$e"; bullets+=("request from ${rq_by:-?}: ${rq_why:-no reason given}"); done
    st_set auto_recycle_at "$now"; st_del auto_recycle_said
    wlog "auto-recycle: launching \`recycle --update --force\` — $(printf '%s; ' "${bullets[@]}" | sed 's/; $//')"
    if wd_launch recycle "$SALA_LOG_DIR/salamander-revive.log" recycle --update --force -- --setenv=SALA_LOCK_WHO=auto-recycle --setenv=SALA_LOCK_WAIT=600 --setenv=SALA_RELAUNCH_KIND=auto; then   # KIND: what a waiting pane is told
        AUTO_LAUNCHED=1; gather_clear
        rm -f ${reqs[@]+"${reqs[@]}"}
        if [ -n "$fresh" ]; then   # served: everything the board lists now except what is held (its recycle comes when its change lands)
            sv=""; for i in $ids; do case "$heldtok" in *" $i "*) ;; *) sv="$sv $i";; esac; done
            st_set auto_recycle_served_ids "${sv# }"
        fi
        st_set recycle_wanted_at 0   # the next look asks the board afresh
        notify "♻️ *Auto-recycle*" "${bullets[@]}" "every idle pane relaunches on the current CLI; a busy one is retried" "Details: $SALA_LOG_DIR/salamander-revive.log"
    else
        notify "🚨 *Auto-recycle could not start*" "${bullets[@]}" "systemd-run refused to launch it; the requests stay, the next try is in an hour" "Details: $WLOG"
    fi
}
[ "$CHECK_ONLY" = 1 ] || auto_recycle
[ "$CHECK_ONLY" = 1 ] || { nd=$("$SALA_BIN" note --deliver 2>&1) && [ -n "$nd" ] && wlog "notes:$(echo "$nd" | tr '\n' ' ')"; }   # a session's next step, back after any relaunch (lib/note.sh)
# THE LATER LIST'S LIMIT: a pane on the deferred list that stays held (background shells that
# never end: an endless until-loop, never relaunched, unseen) is no longer
# silent. The row carries three more fields after the set id: when it was last told, how many times, and when the limit post
# went out. Held for SALA_LATER_RETELL (1 h) since the deferral or the last tell, it is told again the way the recycle first
# told it (the waiting flag, plus the same line pushed into an idle session, since a session held by shells runs no tool call
# for the hook to speak through), at most SALA_LATER_RETELL_MAX (3) times; held for SALA_LATER_LIMIT (3 h), one post names it,
# its versions, how long, and the commands holding it. Nothing here relaunches or gives up a pane: the relaunch and the
# 8-day drop are above and below, as they were. The state lives in the row, so a pane that leaves the list clears it.
later_clear() { [ "${told_n:-0}" -gt 0 ] && waiting_clear "$uuid"; return 0; }   # the flag it raised comes down with the row
later_words() { local h=$(($1 / 3600)) m=$(( ($1 % 3600) / 60 )); if [ "$h" -gt 0 ]; then echo "$h h$([ "$m" -gt 0 ] && echo " $m min")"; else echo "$m min"; fi; }
later_held() {  # in deferred_revive: the pane is held now; told again when due, one post at the limit
    local held_for=$((now - ${since:-0})) base=$told_at what sock st cmds b=() rev line
    [ "$base" -gt "${since:-0}" ] || base=${since:-0}
    if [ "$told_n" -lt "$SALA_LATER_RETELL_MAX" ] && [ $((now - base)) -ge "$SALA_LATER_RETELL" ] && [ -n "$uuid" ]; then
        rm -f "$SALA_WAITING_DIR/$uuid.told"
        waiting_raise "$uuid" "$(relaunch_kind "$(set_val "$dset" why 2>/dev/null)")" "$dset" "$c"   # owner: the claude itself, so the flag lives until that process ends
        what=$(waiting_what "$uuid"); sock=$(session_socket "$c"); st=$(registry_field "$c" status)
        # a session held by shells is idle: no tool call, so the hook never speaks. The line goes in as a message; a turn running
        # now is left to the hook, which says it at the next call
        if [ "$st" != busy ] && [ -n "$sock" ] && session_push "$sock" "$(relaunch_text "${what:-recycle}" "$c")" 2>/dev/null; then waiting_told "$uuid"; fi
        told_n=$((told_n + 1)); told_at=$now
        wlog "deferred: $sess held $(later_words "$held_for") — told again ($told_n of $SALA_LATER_RETELL_MAX): $held"
    fi
    if [ "$posted_at" = 0 ] && [ "$held_for" -ge "$SALA_LATER_LIMIT" ]; then
        cmds=$(later_commands "$c" "$uuid"); rev=$(git -C "$SALA_ROOT" rev-parse --short HEAD 2>/dev/null)
        b+=("held for $(later_words "$held_for") since $(local_human "$since"): $(printf '%s' "$held" | scrub_text | cut -c1-240)")
        b+=("claude $(proc_version "$c")${rev:+, sala $rev}; told again $told_n time(s)")
        while IFS= read -r line; do [ -n "$line" ] && b+=("holding it: $line"); done <<< "$cmds"
        [ -n "$cmds" ] || b+=("no command could be read (the Stop hook's record has none for this stretch and no child process runs)")
        b+=("sala relaunches it once it is free; to free it sooner, end what holds it in the pane")
        sala_post "⚠️ *$sess not relaunched after $(later_words "$held_for")*" "${b[@]}"
        posted_at=$now; wlog "deferred: $sess held $(later_words "$held_for") — limit post sent"
        # THE PARTIAL CLEAR (stackshot's answer): a pane that never goes idle must not hold a flag open for ever. Past this limit
        # (SALA_LATER_LIMIT, the same moment as the post above) it is given up in every flag still waiting for it; a flag with nothing else
        # out closes "at n/N" and fires the post-recycle hook with the pane as skipped. The pane stays on this list and is relaunched
        # once it is free; the flags it was given up in are closed by then.
        set_giveup_pane "$sess" "held for $(later_words "$held_for") by background work or a busy turn, so this recycle stopped waiting for it; sala still relaunches it once it is free"
    fi
    later_row
}
# DEFERRED PANES (lib/revive.sh): a pane a relaunch left because it held scheduled work is relaunched here once that work
# is done; it leaves the list once it is current, its session or claude is gone, or after 8 days. A row that names its
# recycle set (common.sh, "recycle sets") settles there: the pane counted as left behind until
# now, its relaunch post carries the set's label and count and may close the set, and the 8-day drop is a give-up of it.
deferred_revive() {
    [ -s "$SALA_DEFERRED" ] || return 0
    local cur sess since why opid force dset told_at told_n posted_at uuid held pp c nc ver keep=() now row; cur=$(basename "$(readlink -f "$SALA_CLAUDE")"); now=$(date +%s)
    dres() { set_has "$dset" && set_resolve "$dset" "$@"; }   # <ok|gave> <bullet> → 0 when the pane's set took it
    later_row() { row="$sess"$'\t'"$since"$'\t'"$why"$'\t'"${opid:-0}"$'\t'"${force:-0}"$'\t'"${dset:--}"$'\t'"$told_at"$'\t'"$told_n"$'\t'"$posted_at"; }
    while IFS=$'\t' read -r sess since why opid force dset told_at told_n posted_at; do
        [ -n "$sess" ] || continue
        [ "$dset" = - ] && dset=""; : "${told_at:=0}" "${told_n:=0}" "${posted_at:=0}"   # the three after the set id: the later-list state; a row from before has none
        later_row   # an empty set id is written "-": tabs fold in `read`
        # listed since it was deferred (common.sh, no_relaunch): dropped, never relaunched
        no_relaunch "$sess" && { wlog "deferred: $(no_relaunch_line "$sess") — dropped"; dres gave "$sess" "$(no_relaunch_line "$sess")"; continue; }
        pp=$(tmux list-panes -t "$(tmux_win_t "$sess")" -F '#{pane_pid}' 2>/dev/null | head -1)
        [ -n "$pp" ] || { wlog "deferred: $sess gone — dropped"; dres gave "$sess" "$sess: its tmux session is gone"; continue; }
        c=$(claude_pid_under "$pp") || { wlog "deferred: $sess runs no claude now — dropped"; dres gave "$sess" "$sess: runs no claude any more"; continue; }
        registry_conv_r uuid "$c"
        [ "${opid:-0}" != 0 ] && [ "$c" != "$opid" ] && { later_clear; wlog "deferred: $sess relaunched meanwhile (pid $opid → $c) — dropped"; dres ok "$sess" "$sess relaunched meanwhile, on $(proc_version "$c"), $(set_after "$dset" 2>/dev/null)"; continue; }
        ver=$(proc_version "$c")
        [ "$ver" = "$cur" ] && [ "${force:-0}" != 1 ] && { later_clear; wlog "deferred: $sess already on $cur — dropped"; dres ok "$sess" "$sess already on $cur, $(set_after "$dset" 2>/dev/null)"; continue; }
        if [ $((now - ${since:-0})) -gt 691200 ]; then
            later_clear; wlog "deferred: $sess still held after 8 days — dropped"
            dres gave "$sess" "$sess: still held after 8 days (background work or a busy turn), so sala stopped waiting; the next recycle tries again" \
                || sala_post "⚠️ *$sess not relaunched*" "it was still held after 8 days (background work or a busy turn), so sala stopped waiting; the next recycle tries again"
            continue
        fi
        held=$(is_idle_reason "$c")
        if [ -n "$held" ]; then later_held; keep+=("$row"); continue; fi
        # a pane the retry window deferred for an unsubmitted draft is idle to is_idle_reason: not relaunched while
        # the draft stands, and not tried again on every tick (each try would start a retry worker)
        if [ -n "$(pane_draft "$(tmux list-panes -t "$(tmux_win_t "$sess")" -F '#{pane_id}' 2>/dev/null | head -1)" "$c")" ]; then keep+=("$row"); continue; fi
        wlog "deferred: $sess is free now — revive --only$( [ "${force:-0}" = 1 ] && echo ' --force')"
        # SALA_SET: a pane this relaunch leaves to a retry worker stays in its set
        SALA_SET="$dset" "$SALA_BIN" revive --only "$sess" $( [ "${force:-0}" = 1 ] && echo --force ) </dev/null >> "$WLOG" 2>&1   # stdin is the list being read
        nc=$(claude_pid_under "$pp")
        if [ -n "$nc" ] && [ "$nc" != "$c" ]; then
            later_clear; wlog "deferred: $sess relaunched"
            dres ok "$sess" "$sess relaunched on $(proc_version "$nc") once it was free, $(set_after "$dset" 2>/dev/null)" \
                || sala_post "✅ *Recycle: $sess relaunched*" "it is free now; it had been deferred since $(local_human "$since")"
        else keep+=("$row"); fi
    done < "$SALA_DEFERRED"
    printf '%s\n' ${keep[@]+"${keep[@]}"} | grep . > "$SALA_DEFERRED.tmp"; mv -f "$SALA_DEFERRED.tmp" "$SALA_DEFERRED"
}
[ "$CHECK_ONLY" = 1 ] || deferred_revive
[ "$CHECK_ONLY" = 1 ] || sets_tick   # the flag rule over every open recycle set (common.sh, set_sync), before the prune
[ "$CHECK_ONLY" = 1 ] || notice_tick   # expired notices and the delivery files of gone sessions out (lib/notice.sh; nothing runs while no notice and no delivery file exists)
[ "$CHECK_ONLY" = 1 ] || cont_tick   # a pane that moved to a new transcript id keeps its row (lib/continuedin.sh)
[ "$CHECK_ONLY" = 1 ] || bare_tick   # every mapped pane at a bare shell for SALA_BARE_GRACE is revived (lib/barepane.sh)
[ "$CHECK_ONLY" = 1 ] || wrapup_tick   # runs only when SALA_IDLE_WRAPUP=on (off by default): a background agent idle for SALA_IDLE_WRAPUP_MIN is asked to wrap up, then cleared (lib/wrapup.sh)
[ "$CHECK_ONLY" = 1 ] || set_prune   # recycle sets: closed ones after 3 days, any after 9 (common.sh)
[ "$CHECK_ONLY" = 1 ] || { waiting_prune; busy_prune; }   # relaunch-waiting flags whose owner is gone; busy records of sessions long gone
[ "$CHECK_ONLY" = 1 ] || inbox_release_stale   # a relaunch that died left its pane's inbox held: free it after 10 min
# UNMAPPED SESSIONS (the map is a ledger — common.sh): a live claude in a tmux session the pane map
# does not know (started by hand, outside spawn; or a spawn whose row never landed) is reported once — a log line and
# one post per session — and never added from here: `sala adopt NAME` is the honored path. One ps pass for every pane
# (note.sh's ancestry walk in awk); the key clears once the session is mapped, so a later unmapped life is reported again.
unmapped_report() {
    local sess c u k kk su tm sv pt seen=" "
    _panes_get_r pt
    while IFS='|' read -r sess c; do
        [ -n "$sess" ] && [ "$sess" != "$SALA_RC_SESSION" ] || continue
        case "$seen" in *" $sess "*) continue;; esac
        _key_r kk "$sess"; k="unmapped.$kk"
        su=""; [ -r "$SALA_SIDECAR" ] && _tsv_col_r su "$SALA_SIDECAR" "$sess" 2
        if [ -n "$su" ]; then seen="$seen$sess "; _kv_first_r sv "$WSTATE" "$k"; [ -n "$sv" ] && st_del "$k"; continue; fi
        registry_field_r tm "$c" tmux; [ -n "$tm" ] || continue; is_rc_child "$c" && continue   # a pane session, not a `claude -p` under it
        registry_conv_r u "$c"; [ -n "$u" ] && [ "$u" != null ] || continue
        seen="$seen$sess "
        _kv_first_r sv "$WSTATE" "$k"; [ "$sv" = "$u" ] && continue
        st_set "$k" "$u"; wlog "unmapped: '$sess' runs conversation $u with no pane-map row — sala adopt $sess registers it"
        notify "⚠️ *$sess is not in the pane map*" "a live session sala did not spawn (or a spawn whose row never landed): a reboot or recycle could not bring it back" "run: sala adopt $sess"
    done <<< "$pt"
}
[ "$CHECK_ONLY" = 1 ] || unmapped_report
# a hand /rename leaves sala's records on the old name; sala-rename-sync.path follows it within seconds, this is the backstop
if [ "$CHECK_ONLY" = 0 ]; then "$SALA_BIN" rename --sync; [ $? = 3 ] && { wlog "rename sync: the master was renamed; the next run checks it under its new name"; exit 0; }; fi
rc_served_snapshot   # the served Remote Control sessions right now, so the next boot's revive knows which should come back

# checks 2–4 are the master's: with none (the header) they are skipped whole — the block below is not re-indented, so its
# hunks stay where they are; the values the report and the --check line read from it are empty then
pane=""; panepid=""; cpid=""; uuid=""; mlane=""; bridge=""; expected=""
if [ "$NO_MASTER" = 0 ]; then
# 2. master session
if ! tmux has-session -t "=$SALA_MASTER" 2>/dev/null; then
    finding "master tmux session '$SALA_MASTER' is missing"
    uuid=$(st_get uuid)
    restore_master() {
        local mdir; mdir=$(ledger_row "$SALA_MASTER" | cut -f4); [ -n "$mdir" ] && [ -d "$mdir" ] || mdir=$(master_dir)   # the map's cwd first
        tmux new-session -d -s "$SALA_MASTER" -c "$mdir" || return 1
        # the map keeps a row across a missing tmux session (the map is a ledger — common.sh); when the row is
        # gone all the same, put the last-known binding back as an honored add, so revive's shell-pane branch (dedupe
        # guard, effort re-pass) does the resume
        if [ -n "$uuid" ] && [ -z "$(sidecar_uuid_for_session "$SALA_MASTER")" ]; then
            ledger_write add "$SALA_MASTER" "$uuid" "$SALA_MASTER" "$mdir" || wlog "the pane map did not take the master's row back"
        fi
        "$SALA_BIN" revive --only "$SALA_MASTER" >> "$WLOG" 2>&1
        wait_for "$(tmux display -p -t "$(tmux_win_t "$SALA_MASTER")" '#{pane_id}')" claude 30
    }
    heal session "master tmux session '$SALA_MASTER' missing" restore_master
fi

pane=$(tmux list-panes -t "$(tmux_win_t "$SALA_MASTER")" -F '#{pane_id}' | head -1)
panepid=$(tmux display -p -t "$pane" '#{pane_pid}')
cpid=$(claude_pid_under "$panepid" || true)
if [ -n "$cpid" ] && [ "$CHECK_ONLY" = 0 ]; then   # a live master: keep its directory on record (written only when it changes)
    mcwd=$(readlink "/proc/$cpid/cwd" 2>/dev/null || tmux display -p -t "$pane" '#{pane_current_path}')
    [ -n "$mcwd" ] && [ "$mcwd" != "$(st_get "cwd.$SALA_MASTER")" ] && st_set "cwd.$SALA_MASTER" "$mcwd"
fi

# 3. claude in the pane
if [ -z "$cpid" ]; then
    finding "master tmux pane $pane has no claude process"
    [ -z "$(pgrep -P "$panepid" 2>/dev/null)" ] || { wlog "master pane busy with a non-claude child; leaving it"; exit 0; }
    heal claude "master tmux pane '$SALA_MASTER' has no claude process" sh -c "'$SALA_BIN' revive --only '$SALA_MASTER' >> '$WLOG' 2>&1"
fi
registry_conv_r uuid "$cpid"
[ -n "$uuid" ] && st_set uuid "$uuid"

# 4. bridge
: "${SALA_BRIDGE_SETTLE:=20}"   # seconds after /remote-control is typed before the bridge id is read back (the tests set it short)
# NO REMOTE CONTROL ON THE API LANE (common.sh, lanes): a claude on a key has no claude.ai
# login, so no bridge ever comes up there, and the heal below would type /remote-control every cooldown and post a 🚨
# each time. The lane the master RUNS on decides (its environment; the recorded lane where that cannot be read): on the
# api lane the bridge is neither read nor healed — said once in the log — and the rest of this run goes on.
mlane=$(lane_running "$cpid" "$SALA_MASTER")
bridge=""; expected=$(st_get bridge)
if lane_rc "$mlane"; then
    [ -z "$(st_get lane_norc)" ] || st_del lane_norc
    bridge=$(registry_field "$cpid" bridgeSessionId); [ "$bridge" = null ] && bridge=""
    [ -n "$bridge" ] || bridge=$(bridge_for_uuid "$uuid")
    screen=$(tmux capture-pane -p -t "$pane" 2>/dev/null | tail -40)
    down=0
    echo "$screen" | grep -qE 'run /remote-control to reconnect|Remote Control disconnected|run /remote-control in this session' && down=1
    if [ "$down" = 0 ] && [ -z "$bridge" ]; then
        age=$(proc_etime "$cpid")
        [ "$age" -ge 300 ] && down=1
    fi
    if [ "$down" = 1 ]; then
        finding "master Remote Control bridge is down (tmux pane $pane)"
        reconnect() {
            is_idle "$cpid" || { wlog "master is busy; not typing /remote-control now"; return 1; }
            prompt_clears "$pane" 5 || { wlog "master shows a prompt; not typing /remote-control now"; return 1; }
            submit "$pane" "/remote-control"; sleep "$SALA_BRIDGE_SETTLE"   # the bridge takes a while to come up and register
            b=$(registry_field "$cpid" bridgeSessionId); [ "$b" = null ] && b=""; [ -n "$b" ] || b=$(bridge_for_uuid "$uuid")
            [ -n "$b" ] || return 1
            wlog "bridge after reconnect: $b (was ${expected:-none})"; return 0
        }
        heal bridge "master '$SALA_MASTER' Remote Control bridge down" reconnect
    fi
elif [ "$(st_get lane_norc)" != "$mlane" ]; then
    [ "$CHECK_ONLY" = 1 ] || st_set lane_norc "$mlane"
    wlog "bridge: the master runs on the $mlane lane, which has no Remote Control — the bridge check is off until it runs on a claude.ai lane again"
fi
if [ -n "$bridge" ]; then
    if [ -n "$expected" ] && [ "$bridge" != "$expected" ]; then
        wlog "bridge changed: $expected → $bridge"; notify "⚠️ *$SALA_MASTER moved to a new claude.ai session*" "its Remote Control link now points at a different session" "check claude.ai for a twin; the old one may need archiving" "Details: $WLOG"
    fi
    st_set bridge "$bridge"
fi
fi   # NO_MASTER: the end of checks 2–4
# 5. post-boot report: once revive's boot sweep is done and the master is idle, one turn in its inbox; with no master, one
# Slack post per boot, the same report, at once (the header)
# A CLEAN REBOOT (`sala reboot --go` left a marker from the previous boot): its boot half runs first, detached — hooks up
# in order, panes verified against the snapshot, then resume — and its result lines join this report.
RMARK="$SALA_LOG_DIR/salamander-reboot.marker"; RRESULT="$SALA_LOG_DIR/salamander-reboot.result"
if boot_pending && [ -s "$RMARK" ] && [ "$(_kv_first "$RMARK" boot_id)" != "$BOOT" ]; then
    # launched OUTSIDE this service's cgroup: systemd kills a oneshot's leftovers when it exits, so a setsid child dies
    # with watch (the boot half was once killed at launch and logged nothing)
    launch_after_boot() {
        if command -v systemd-run >/dev/null 2>&1 && systemd-run --user --quiet --collect --unit="sala-reboot-after-boot-$(date +%s)" \
               bash -c "exec '$SALA_BIN' reboot --after-boot >> '$SALA_LOG_DIR/salamander-reboot.log' 2>&1"; then return 0; fi
        setsid "$SALA_BIN" reboot --after-boot </dev/null >> "$SALA_LOG_DIR/salamander-reboot.log" 2>&1 &
    }
    running() { pgrep -f 'bin/(sala|salamander) reboot --after-boot' >/dev/null 2>&1; }
    if [ "$(st_get reboot_after_boot)" != "$BOOT" ]; then
        st_set reboot_after_boot "$BOOT"; st_set reboot_after_boot_at "$(date +%s)"; wlog "clean reboot: launching its boot half"; launch_after_boot
    elif [ "$(head -1 "$RRESULT" 2>/dev/null)" != "$BOOT" ] && ! running && [ -s "$RMARK" ]; then
        # it is gone without a result: say so once, relaunch once
        if [ "$(st_get reboot_after_boot_relaunched)" != "$BOOT" ]; then
            st_set reboot_after_boot_relaunched "$BOOT"; wlog "clean reboot: boot half gone without a result — relaunching once"; launch_after_boot
        elif [ "$(st_get reboot_after_boot_told)" != "$BOOT" ]; then
            st_set reboot_after_boot_told "$BOOT"
            m="[sala reboot] the boot half died twice without a result — hooks may still be paused. Run \`sala reboot --status\`, then \`sala reboot --resume\` (log ~/.claude/salamander-reboot.log)."
            sock=$(session_socket "$cpid"); { [ -n "$sock" ] && session_push "$sock" "$m"; } || notify "🚨 *Reboot boot half died twice*" "inbound notices may still be paused" "run \`sala reboot --status\`, then \`sala reboot --resume\`" "Details: ~/.claude/salamander-reboot.log"
        fi
    fi
    # its result, once written, is the report's cue: a hook it still watches afterwards is told to the master on its own
    [ "$(head -1 "$RRESULT" 2>/dev/null)" != "$BOOT" ] && [ "$BOOT_AGE" -lt "$SALA_BOOT_DEADLINE" ] \
        && { wlog "post-boot report: waiting for the clean-reboot boot half"; exit 0; }
fi
if boot_pending; then
    if [ "$(head -1 "$SALA_BOOT_REC" 2>/dev/null)" != "$BOOT" ] && [ "$BOOT_AGE" -lt "$SALA_BOOT_GRACE" ]; then
        wlog "post-boot report: waiting for revive's boot summary ($((BOOT_AGE/60)) min since boot)"; exit 0
    fi
    if [ "$NO_MASTER" = 1 ]; then
        boot_done; mapfile -t rb < <(report_bullets); notify "ℹ️ *$(hostname) came back up — the post-boot report*" "no master session is configured, so it comes here" "${rb[@]}"
        wlog "post-boot report posted (no master session)"; exit 0
    fi
    why=$(is_idle_reason "$cpid"); [ -z "$why" ] && pane_prompt "$pane" && why="a terminal prompt is showing"
    [ -z "$why" ] && [ -n "$(pane_draft "$pane")" ] && why="unsubmitted text at the prompt"
    if [ -n "$why" ] && [ "$BOOT_AGE" -lt "$SALA_BOOT_DEADLINE" ]; then wlog "post-boot report: master not idle yet — $why"; exit 0; fi
    sock=$(session_socket "$cpid")
    if [ -n "$sock" ] && session_push "$sock" "$(boot_report inbox)"; then
        boot_done; wlog "post-boot report delivered to '$SALA_MASTER' (pid $cpid)${why:+ past the deadline, while: $why}"
    else
        boot_done; mapfile -t rb < <(report_bullets); notify "⚠️ *Post-boot report not delivered to $SALA_MASTER*" "$([ -n "$sock" ] && echo "its inbox refused it" || echo "it has no messaging socket"); here it is:" "${rb[@]}"
    fi
fi
if [ "$CHECK_ONLY" = 1 ]; then
    if [ "$NO_MASTER" = 1 ]; then u=$(st_get master_unset); echo "healthy: no master session (SALA_MASTER unset${u:+ on purpose, $(local_human "${u##* }"), was '${u%% *}'}) — no master is kept alive; the operation queue, the watches, the bare-pane revive and the post-boot report (to Slack) run"
    else echo "healthy: tmux session $SALA_MASTER (pane $pane) · claude pid $cpid on conversation $uuid · $(lane_rc "$mlane" && echo "Remote Control bridge ${bridge:-none}" || echo "no Remote Control (the $mlane lane)")"; fi
fi
exit 0
