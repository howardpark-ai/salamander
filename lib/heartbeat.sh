# lib/heartbeat.sh — publish the fleet's CLI versions and live sessions into a shared git repo.
#
# A board or dashboard that lives elsewhere (the author's: Stackshot) needs two facts per machine: which Claude
# Code version its launcher is on, and which conversations are live, under what name, at what Remote Control
# address. This verb writes both under <repo>/<dir>/<letter>/ and pushes them; the consumer renders them at its
# own pace. Nothing else is written — the store's items belong to their own writer.
#
# ONE WRITER: the box that drives the fleet (SALA_FLEET_HOSTS set) writes every box's files —
# its own from the local registry, the others' from one ssh round-trip each (FLEET SWEEP below), which is also the
# fleet's liveness signal. The other boxes run nothing for the board. A box without SALA_FLEET_HOSTS still
# publishes itself when run by hand (a standalone install).
#
#   salamander heartbeat              sweep, write what changed, commit, fetch + rebase + push (only when there is a commit)
#   salamander heartbeat --no-push    sweep, write + commit only
#   salamander heartbeat --dry-run    sweep and print every document, touch nothing
#   salamander heartbeat --check      0 when the last run is younger than SALA_HEARTBEAT_STALE seconds
#
# Contract of the two files (the board app; readers as listed below):
#   machine.json   READERS: sala itself (`fleet_ssh` and `claude`: fleet_awake in lib/watch.sh, lib/update.sh, lib/settings-apply.sh).
#                  stackshot does NOT read it: it merged sala's machine.json until a later release and no longer does; of this store it
#                  reads only `url` from sessions.json (below). Its own fleet view (clients.py) carries fields sala never writes
#                  (online, source, setup, updates). No other reader is known; `master` and `master_session` are kept for an off-box
#                  caller that resolves the master from the store (lib/master.sh), and nothing reads them today.
#                  {"letter","fleet","claude","checked","master","master_session","fleet_ssh"}   checked = ISO-8601 UTC ("Z")
#                  of the last CHANGE to these facts, not of the last run;
#                  fleet_ssh = {"<fleet name>": {"letter","ok","since"}} on the driving box, else {}: ok = the box answered
#                  ssh on the last sweep (online), since = when it last flipped; a box that is offline keeps its last files;
#                  master = SALA_MASTER (the operator session `watch` keeps alive; "" when unset), master_session = its conversation uuid while live
#                  (a "hub" field, the sweep's fast-forward of a Windows box's ops-repo checkout, went with the Windows
#                  sweep: Thu Oct 15th 2026)
#   sessions.json  {"<transcript uuid>": {"name","url","seen","machine"}}
#                  A CONTRACT: the board app reads
#                  ~/.local/state/salamander/fleet/<letter>/sessions.json directly and takes each row's url, matched by its
#                  transcript-uuid key; reply-links (in the ops repo) reads the same file. Tell the board's main session BEFORE changing the
#                  path, the url field or the transcript-uuid key.
#                  keyed by the pane's TRANSCRIPT UUID (the registry's sessionId — the identity that
#                  survives resumes and bridge breaks); name = the /rename label; url = the session's link: on the
#                  writer's own rows the sala-web link SALA_SESSION_URL gives (Tue Oct 13th 2026; SESSION LINKS in
#                  lib/common.sh), whether or not the session is bridged; on a swept box's rows, and wherever no template is in
#                  force, the current Remote Control address, "" while the bridge is down; previous_name + renamed_at (ISO-8601 UTC) only on a
#                  coordinator-machine row that `salamander rename` renamed and whose name is still the one it gave (the hand-off
#                  to stackshot, which fixes the names it keeps itself); live sessions only. The writer's own box: EVERY
#                  live pane (a registry file whose pid is running and that names a tmux pane), bridged or not, each with its
#                  sala-web url (reply-links and stackshot read each session's link from here); its rows for an
#                  unbridged session carry the same fields as a bridged one's. A swept box: a registry file whose pid is
#                  running and that has a Remote Control bridge — headless runs are left out. seen = when the row last changed.
#   session-registry.json  (phase 3 of the session registry; a third file, the live store only, this box's own): {"schema":1,"machine",
#                  "written","sessions":{"<sala session id>": {id,name,aliases,project,project_key,role,lane,model,effort,pane,cwd,state,created,
#                  retired_at,transcripts[{id,machine,at,why}]}}}. `written` is refreshed on EVERY run (a stale file is a dead heartbeat, not a quiet
#                  fleet); retired rows stay. Not published (the last good file stays, one line in sessions.log) when SALA_SESSIONS=off or sessions.json
#                  is missing or corrupt. docs/session-registry.md; docs/stackshot-contracts.md interface 19: tell the board's main session BEFORE changing it.
#
# Portability: plain bash + python3 + git on the writer; a swept box needs only ssh and a POSIX shell (Linux or macOS) — no
# salamander, git or python there. Schedule it on the writer: systemd/sala-heartbeat.timer (every 5 min) or
# launchd/ai.salamander.heartbeat.plist. The Windows side of the sweep (a PowerShell payload, the hub and stackshot pulls, the
# registry-age fallback SALA_HEARTBEAT_WIN_TTL) was retired with Thu Oct 15th 2026, sala off Windows; the key
# is ignored where a config still sets it.

: "${SALA_HEARTBEAT_STATE_DIR:=}"   # LIVE store: a local directory, <dir>/<letter>/{machine,sessions}.json, rewritten on change (the consumer reads it here)
: "${SALA_HEARTBEAT_REPO:=}"        # optional git checkout the files are also committed into (see SALA_HEARTBEAT_GIT)
: "${SALA_HEARTBEAT_GIT:=full}"     # what goes into git: full (every file) · master (only this box's master record) · off
: "${SALA_HEARTBEAT_DIR:=}"         # path of the store inside the repo, e.g. ops/board-data
: "${SALA_HEARTBEAT_LETTER:=}"      # this machine's directory under the store; default: from SALA_FLEET_NAMES
: "${SALA_HEARTBEAT_NAME:=}"        # this machine's fleet name; default: from SALA_FLEET_NAMES, else hostname
: "${SALA_FLEET_NAMES:=}"           # TSV  <os hostname>\t<fleet name>\t<letter>  ('#' comments), hostname case-insensitive
: "${SALA_HEARTBEAT_STALE:=1800}"   # --check: seconds after which the last heartbeat counts as missing

mode=run
case "${1:-}" in
    '') ;; --no-push) mode=nopush ;; --dry-run) mode=dry ;; --check) mode=check ;;
    *) die "usage: salamander heartbeat [--no-push|--dry-run|--check]" ;;
esac
[ -n "$SALA_HEARTBEAT_REPO$SALA_HEARTBEAT_STATE_DIR" ] || { echo "heartbeat: SALA_HEARTBEAT_STATE_DIR and SALA_HEARTBEAT_REPO not set — nothing to publish to"; [ "$mode" = check ] && exit 1; exit 0; }
state="${SALA_HEARTBEAT_STATE_DIR/#\~/$HOME}"
repo=""; [ "$SALA_HEARTBEAT_GIT" = off ] || repo="${SALA_HEARTBEAT_REPO/#\~/$HOME}"
if [ -n "$repo" ]; then
    [ -n "$SALA_HEARTBEAT_DIR" ] || die "heartbeat: SALA_HEARTBEAT_DIR not set"
    [ -d "$repo/.git" ] || die "heartbeat: $repo is not a git checkout"
fi

host=${_SALA_HN,,}
letter="$SALA_HEARTBEAT_LETTER"; name="$SALA_HEARTBEAT_NAME"
if [ -n "$SALA_FLEET_NAMES" ] && [ -r "${SALA_FLEET_NAMES/#\~/$HOME}" ]; then
    row=$(awk -F'\t' -v h="$host" '!/^#/ && tolower($1)==h {print; exit}' "${SALA_FLEET_NAMES/#\~/$HOME}")
    [ -n "$letter" ] || letter=$(printf '%s' "$row" | cut -f3)
    [ -n "$name" ]   || name=$(printf '%s' "$row" | cut -f2)
fi
[ -n "$letter" ] || die "heartbeat: no letter for '$host' — set SALA_HEARTBEAT_LETTER or add the host to SALA_FLEET_NAMES"
: "${name:=$host}"
mine="$repo/$SALA_HEARTBEAT_DIR/$letter"

if [ "$mode" = check ]; then
    f="$SALA_LOG_DIR/salamander-heartbeat.last"; [ -r "$f" ] || { echo "heartbeat($letter): never run"; exit 1; }
    age=$(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0) ))
    [ "$age" -le "$SALA_HEARTBEAT_STALE" ] && { echo "heartbeat($letter): ${age}s ago"; exit 0; }
    echo "heartbeat($letter): stale (${age}s ago)"; exit 1
fi

# one heartbeat at a time per repo: a hook-driven run and the timer may coincide (git index.lock); taken before
# any work, so the fleet sweep runs once
if [ "$mode" != dry ] && command -v flock >/dev/null 2>&1 && [ -z "${SALA_HEARTBEAT_LOCKED:-}" ]; then
    export SALA_HEARTBEAT_LOCKED=1
    mkdir -p "$SALA_LOG_DIR"; exec flock -w 120 "$SALA_LOG_DIR/salamander-heartbeat.lock" "$SALA_BIN" heartbeat "$@"
fi

cver=$("$SALA_CLAUDE" --version 2>/dev/null | awk '{print $1; exit}')
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# the master session (SALA_MASTER) and its conversation id, so a session that cannot read this box's config — cloud,
# Cowork, another machine — can still resolve the operator for "recycle claude" from the store
master="${SALA_MASTER:-}"; master_sid=""
if [ -n "$master" ] && command -v tmux >/dev/null 2>&1 && tmux has-session -t "=$master" 2>/dev/null; then
    mp=$(claude_pid_under "$(tmux display -p -t "$(tmux list-panes -t "$(tmux_win_t "$master")" -F '#{pane_id}' | head -1)" '#{pane_pid}')" 2>/dev/null) && master_sid=$(registry_field "$mp" sessionId)
fi

# FLEET SWEEP: the box that drives the fleet (SALA_FLEET_HOSTS set) collects the other boxes'
# facts itself, over the same ssh round-trip that is the fleet's liveness signal: CLI version and live sessions
# answer → "ok" and their files are refreshed; no answer → offline (asleep, off, or stuck behind a Tailscale
# sign-in alike — every operation on a box goes over ssh) and their files keep the last known facts. So the
# other boxes run nothing for the board: no task, no push, no salamander needed there. Published in this box's
# machine.json as "fleet_ssh": {"<fleet name>": {"letter","ok","since"}}, since = the last flip.
# Remote payload, one line each: V:<claude --version> · S:<pid>|<alive 1/0>|<registry json on one line>. The sweep pulls
# nothing on a box: the fast-forward of a Windows box's ops-repo and stackshot checkouts (the H: and K: lines) was
# retired with the Windows sweep. The coordinator's own ~/stackshot is stackshot's production checkout, moved only by
# stackshot's own deploy; the driving box never runs the payload on itself (fleet_hosts drops its own hostname).
REMOTE_SH='c=$(command -v claude || echo "$HOME/.local/bin/claude"); echo "V:$("$c" --version 2>/dev/null | head -1)"
for f in "$HOME"/.claude/sessions/*.json; do [ -r "$f" ] || continue; p=${f##*/}; p=${p%.json}
  kill -0 "$p" 2>/dev/null && a=1 || a=0; printf "S:%s|%s|%s\n" "$p" "$a" "$(tr "\n" " " < "$f")"; done'
fdir=""
if [ -n "${SALA_FLEET_HOSTS:-}" ]; then
    # WRITE GUARD (/tmp over quota failed these writes): a probe's status is written only after
    # its output is, and a host with no status file means a write failed — the run then stops before it publishes, so a
    # write failure never reads as a box gone offline or a box with no sessions
    fdir=$(mktemp -d "${TMPDIR:-/tmp}/sala-heartbeat.XXXXXX") && trap 'rm -rf "${fdir:?}"' EXIT && : > "$fdir/.w" || { echo "heartbeat skipped: cannot write a temp dir (disk full or over quota?)" >&2; exit 1; }
    for h in $(fleet_hosts); do (
        fleet_shell "$h" >/dev/null || { echo fail > "$fdir/$h.status"; exit 0; }
        out=$(timeout 30 "${SALA_SSH[@]}" "$h" "$REMOTE_SH" 2>/dev/null)
        printf '%s\n' "$out" > "$fdir/$h.out" && echo ok > "$fdir/$h.status"
    ) & done; wait
    for h in $(fleet_hosts); do [ -s "$fdir/$h.status" ] && continue
        rm -rf "${fdir:?}"; echo "heartbeat skipped: could not record $h's probe (disk full or over quota?) — nothing published" >&2; exit 1; done
fi

# BUILD + WRITE. A file changes only when a fact does — version, master, the session set, a name or url, an
# ssh flip — so a run with nothing new writes nothing and commits nothing (the first cut stamped every run and
# filled the store repo with commits). Unchanged facts keep their old "checked"/"seen" stamps.
report=$(HB_NOW="$now" HB_STATE="$state" HB_GITMODE="$SALA_HEARTBEAT_GIT" HB_STORE="${repo:+$repo/$SALA_HEARTBEAT_DIR}" HB_FLEET="${SALA_FLEET_NAMES/#\~/$HOME}" HB_MODE="$mode" \
    HB_LETTER="$letter" HB_NAME="$name" HB_CVER="$cver" HB_MASTER="$master" HB_MASTER_SID="$master_sid" \
    HB_PST="$SALA_LOG_DIR/salamander-fleet-ssh.json" HB_FDIR="$fdir" \
    HB_SESSIONS_PY="$SALA_SESSIONS_PY" HB_SESSIONS_FILE="$SALA_SESSIONS_FILE" HB_SESSIONS_LOG="$SALA_SESSIONS_LOG" HB_SESSIONS_ON="$(sessions_on && echo 1 || echo 0)" \
    HB_RENAMES="$SALA_LOG_DIR/salamander-renames.jsonl" HB_URL_PY="$SALA_SESSION_URL_PY" HB_URL_TPL="$(session_url_template)" \
    python3 - "$SALA_REG_DIR" <<'PY'
import json, glob, os, sys, time
E =os.environ; now = E["HB_NOW"]; store = E["HB_STORE"]; state = E["HB_STATE"]; gitmode = E["HB_GITMODE"]; dry = E["HB_MODE"] == "dry"
def load(p):
    try: return json.load(open(p, encoding="utf-8"))
    except Exception: return {}
exec(E["HB_URL_PY"])   # session_url(name, bridge, tpl): the one definition, in lib/common.sh
# SESSION LINKS (Tue Oct 13th 2026: term links replace the remote-control links, and the link comes from sala): a row of THIS box carries its session's sala-web link (tpl = SALA_SESSION_URL, or sala-web's address when this
# box drives the fleet), bridged or not. A swept box's rows are built without tpl and keep the claude.ai link: sala-web reaches
# only the panes of the box it runs on. The name in the link is the registry name, the one sala-web matches #s= against.
def row(d, letter, tpl=""):
    name = d.get("name") or ""
    return {"name": name, "url": session_url(name, d.get("bridgeSessionId") or "", tpl), "seen": now, "machine": letter}
def write_if_changed(p, t):
    try: old = open(p, encoding="utf-8").read()
    except Exception: old = None
    if old == t: return False
    os.makedirs(os.path.dirname(p), exist_ok=True); tmp = p + ".tmp"
    open(tmp, "w", encoding="utf-8").write(t); os.replace(tmp, p); return True
def dumps(machine, sessions):
    return json.dumps(machine) + "\n", json.dumps(sessions, ensure_ascii=False, indent=1, sort_keys=True) + "\n"
def publish(letter, machine, sessions):
    """write <letter>/{machine,sessions}.json into the live store (and git, per SALA_HEARTBEAT_GIT), keeping old stamps
    where nothing changed; → the changed GIT files (what the commit carries)"""
    base = state or store
    om, os_ = load(os.path.join(base, letter, "machine.json")), load(os.path.join(base, letter, "sessions.json"))
    strip = lambda x: {k: v for k, v in x.items() if k != "checked"}
    if om.get("checked") and strip(om) == strip(machine): machine["checked"] = om["checked"]
    for sid, r in sessions.items():
        p = os_.get(sid) or {}
        if p.get("seen") and all(p.get(k) == r[k] for k in ("name", "url", "machine")): r["seen"] = p["seen"]
    docs = {}
    if state: docs[os.path.join(state, letter)] = dumps(machine, sessions)
    if store and gitmode == "full": docs[os.path.join(store, letter)] = dumps(machine, sessions)
    elif store and gitmode == "master" and letter == E["HB_LETTER"]:
        # the MASTER RECORD — held in git until the off-box master lookup is settled: who the master
        # is and its session row, nothing that changes on a quiet day
        ms = machine.get("master_session") or ""
        docs[os.path.join(store, letter)] = dumps({k: machine.get(k, "") for k in ("letter", "fleet", "master", "master_session")},
                                                  {ms: dict(sessions[ms], seen="")} if ms in sessions else {})
    changed = []
    for d, (mtxt, stxt) in docs.items():
        # the path, url and uuid key are a contract with stackshot and reply-links (header, sessions.json)
        mp, sp = os.path.join(d, "machine.json"), os.path.join(d, "sessions.json")
        if dry: print(f"== {mp}\n{mtxt}== {sp}\n{stxt}", file=sys.stderr); continue
        for p, t in ((mp, mtxt), (sp, stxt)):
            if write_if_changed(p, t) and store and p.startswith(store): changed.append(p)
    return changed

def publish_registry(letter):
    """SESSION REGISTRY (phase 3): <live store>/<letter>/session-registry.json from THIS box's sessions.json
    (lib/sessions.py export_doc; docs/session-registry.md, docs/stackshot-contracts.md interface 19). Differs from the two files
    above on purpose: `written` is stamped on EVERY run, so a reader tells a stale file from a quiet fleet (stackshot's engineer);
    the write is still atomic (write_if_changed: tmp + replace) and skips a run in the same second as the last. Live store only
    (never git: it carries cwds). Not published when SALA_SESSIONS=off or sessions.json is missing or corrupt: the last good file
    stays and sessions.log gets one line (not again while the last line says the same)."""
    if E.get("HB_SESSIONS_ON") != "1" or not state: return
    def note(msg):
        lg = E.get("HB_SESSIONS_LOG", "")
        if not lg: return
        try:
            try: last = open(lg, encoding="utf-8", errors="replace").read()[-2000:].rstrip("\n").rsplit("\n", 1)[-1]
            except Exception: last = ""
            if f"\theartbeat\t" in last and last.split("\t")[4:5] == [msg]: return
            os.makedirs(os.path.dirname(lg) or ".", exist_ok=True)
            open(lg, "a", encoding="utf-8").write("\t".join([time.strftime("%Y-%m-%dT%H:%M:%S%z"), "heartbeat", "-", "-", msg, "heartbeat"]) + "\n")
        except Exception: pass
    try:
        import importlib.util
        sp = importlib.util.spec_from_file_location("sala_sessions", E["HB_SESSIONS_PY"])
        mod = importlib.util.module_from_spec(sp); sp.loader.exec_module(mod)
        doc = mod.export_doc(E["HB_SESSIONS_FILE"], letter, now)
    except Exception as e:
        note("session-registry.json not published, the last good file stays: %s" % e); return
    txt = json.dumps(doc, ensure_ascii=False, indent=1) + "\n"
    p = os.path.join(state, letter, "session-registry.json")
    if dry: print(f"== {p}\n{txt}", file=sys.stderr); return
    try: write_if_changed(p, txt)
    except Exception as e: note("session-registry.json not written: %s" % e)

changed, summary = [], []
renames = {}   # uuid → its latest `sala rename` record (lib/rename.sh)
try:
    for line in open(E.get("HB_RENAMES", ""), encoding="utf-8"):
        try: r = json.loads(line); renames[r["uuid"]] = r
        except Exception: pass
except Exception: pass
# ── this box
sess = {}
regrows = []
for f in glob.glob(os.path.join(sys.argv[1], "*.json")):
    d = load(f); pid = os.path.basename(f)[:-5]; sid = d.get("sessionId") or ""
    if not sid: continue
    try: os.kill(int(pid), 0)
    except PermissionError: pass
    except Exception: continue
    regrows.append(d)
for d in regrows:
    sid = d.get("sessionId") or ""
    if not d.get("tmux"): continue
    # A PANE PARKED ON A BACKGROUND JOB: the pane's row keeps the pre-move conversation, the live one is the job's row
    # (kind bg, no tmux, jobId = the pane's parkedJobId, which also holds the Remote Control bridge). One entry, keyed by the live
    # conversation, under the pane's name; the job's row is not an entry of its own (it has no tmux, so the loop skips it).
    pj = d.get("parkedJobId")
    if pj:
        for j in regrows:
            if j is not d and j.get("sessionId") and (j.get("jobId") == pj or j.get("sessionId") == pj):
                sid = j["sessionId"]
                if not d.get("bridgeSessionId") and j.get("bridgeSessionId"): d = dict(d, bridgeSessionId=j["bridgeSessionId"])
                break
    sess[sid] = row(d, E["HB_LETTER"], E["HB_URL_TPL"])   # this box's own row: its link template (SESSION LINKS above)
    rn = renames.get(sid)
    if rn and rn.get("to") == sess[sid]["name"]:   # `sala rename` gave it this name: say what it was, for stackshot
        sess[sid]["previous_name"] = rn.get("from", ""); sess[sid]["renamed_at"] = rn.get("at", "")

# ── the fleet
letters = {}
try:
    for line in open(E.get("HB_FLEET", "")):
        if line.startswith("#") or not line.strip(): continue
        c = line.rstrip("\n").split("\t")
        if len(c) >= 3: letters[c[1].strip()] = c[2].strip()
except Exception: pass
fleet = {}; fd = E.get("HB_FDIR")
# the ssh flip's memory is salamander-fleet-ssh.json (pst): a box's `since` holds through its sleep
pst = {}
if fd:
    prev = load(E["HB_PST"])
    for st in sorted(glob.glob(os.path.join(fd, "*.status"))):
        h = os.path.basename(st)[:-7]; ok = open(st).read().strip() == "ok"; L = letters.get(h, "")
        p = prev.get(h, {})
        fleet[h] = {"letter": L, "ok": ok, "since": p["since"] if p.get("ok") == ok and p.get("since") else now}
        pst[h] = dict(fleet[h])
        if not ok or not L:
            summary.append(f"{h} offline"); continue
        ver, rs = "", {}
        for line in open(os.path.join(fd, h + ".out"), encoding="utf-8", errors="replace"):
            line = line.rstrip("\n")
            if line.startswith("V:"): ver = (line[2:].split() or [""])[0]
            elif line.startswith("S:"):
                try: _, a, js = line[2:].split("|", 2)
                except ValueError: continue
                if a != "1": continue
                try: d = json.loads(js)
                except Exception: continue
                # only sessions the owner can reach: a Remote Control address. A headless run (`claude -p` from /provision,
                # a scheduled job) has none and lives for minutes — listing it made a commit when it came and when it went
                # (one provision once made a burst of commits)
                if d.get("sessionId") and d.get("bridgeSessionId"): rs[d["sessionId"]] = row(d, L)
        om = load(os.path.join(state or store, L, "machine.json"))
        m = {"letter": L, "fleet": h, "claude": ver or om.get("claude", ""), "checked": now, "master": "", "master_session": "", "fleet_ssh": {}}
        changed += publish(L, m, rs); summary.append(f"{h} claude {ver or '?'} · {len(rs)}")
    if not dry: json.dump(pst, open(E["HB_PST"], "w"), indent=1, sort_keys=True)

me = {"letter": E["HB_LETTER"], "fleet": E["HB_NAME"], "claude": E["HB_CVER"], "checked": now, "master": E["HB_MASTER"],
      "master_session": E["HB_MASTER_SID"], "fleet_ssh": fleet}
if not E["HB_CVER"]:
    me["claude"] = load(os.path.join(state or store, E["HB_LETTER"], "machine.json")).get("claude", "")
changed = publish(E["HB_LETTER"], me, sess) + changed
publish_registry(E["HB_LETTER"])   # this box's registry only: a swept box's sessions.json is not reachable from here
print(json.dumps({"changed": changed, "n": len(sess), "fleet": summary}))
PY
) || die "heartbeat: python3 failed"
[ -n "$fdir" ] && rm -rf "${fdir:?}"
[ "$mode" = dry ] && exit 0
date +%s > "$SALA_LOG_DIR/salamander-heartbeat.last" 2>/dev/null

changed=$(python3 -c 'import json,sys,os; d=json.loads(sys.argv[1]); print("\n".join(os.path.relpath(p, sys.argv[2]) for p in d["changed"]))' "$report" "${repo:-/}")
letters=$(printf '%s\n' "$changed" | awk -F/ 'NF>1 {print $(NF-1)}' | sort -u | paste -sd, -)
if [ -n "$changed" ] && [ -n "$repo" ]; then
    # shellcheck disable=SC2086
    git -C "$repo" add -- $changed 2>/dev/null
    git -C "$repo" commit --quiet --only -m "board($letters): heartbeat" -- $changed >/dev/null 2>&1 || true
fi
if [ "$mode" = run ] && [ -n "$repo" ] && [ -n "$(git -C "$repo" log --oneline "@{u}..HEAD" -- "$SALA_HEARTBEAT_DIR" 2>/dev/null)" ]; then
    branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null); : "${branch:=main}"
    if git -C "$repo" fetch --quiet origin "$branch" 2>/dev/null; then
        if git -C "$repo" rebase --autostash --quiet "origin/$branch" >/dev/null 2>&1; then
            git -C "$repo" push --quiet origin "$branch" 2>/dev/null || echo "  ⚠ push failed — the heartbeat is committed locally and goes out with the next one" >&2
        else git -C "$repo" rebase --abort >/dev/null 2>&1; echo "  ⚠ rebase onto origin/$branch failed — left the checkout as it was" >&2; fi
    else echo "  ⚠ fetch failed (offline?) — committed locally" >&2; fi
fi
python3 - "$report" "$letter" "$name" "$cver" "$letters" <<'PY'
import json, sys
d = json.loads(sys.argv[1]); _, _, letter, name, cver, changed = sys.argv
line = "heartbeat(%s): %s claude %s · %d live session(s)" % (letter, name, cver or "?", d["n"])
if d["fleet"]: line += " · fleet: " + "; ".join(d["fleet"])
print(line + (" · changed: " + changed if changed else " · nothing changed"))
PY
