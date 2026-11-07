#!/usr/bin/env python3
"""lib/sessions.py — the session registry's file operations (phases 1 to 3). Standard library only.

The registry is $SALA_STATE_DIR/sessions.json: one row per session, with an id of its own (uuid4) that outlives a rename
and a fresh conversation. Phases 1 and 2 only record it; phase 3 publishes it (export_doc, used by the heartbeat) and
resolves a reference to a row (resolve, `sessions resolve`), both read-only (docs/session-registry.md).

This file never takes a lock: lib/common.sh runs it under the pane map's lock (fd 6), the same one ledger_write holds, so
the two files are never written by two runs at once. It never raises into its caller's work either: a failure is one line
in sessions.log and exit 1, and the shell ignores it (the pane map is the authority until phase 4).

  sessions.py [--file F] [--log L] [--history H] [--keep DAYS] [--caller WHO] [--machine M] <command> [args]

  dual add|adopt SESSION UUID NAME CWD [--lane L] [--model M] [--effort E]   the pane map took an add/adopt
  dual rename OLD NEW UUID NAME CWD                                          … a rename (the id stays, the old name becomes an alias)
  dual retire SESSION [NAME]                                                 … a retire (state=retired; the row stays)
  set SESSION key=value… [--mint UUID,NAME,CWD,PANE]                         copy fields into the live row (lane, model, effort, project, role, side*, spawned_by, throwaway);
                                                                             a project, role or side value clears the throwaway tag
  prepare NAME PANE CWD [--lane L] [--model M] [--effort E]                  spawn: the live row of NAME (made now, without a conversation, if
                                                                             there is none) → its id on stdout, exported to the new pane
  abandon ID                                                                 spawn failed: drop that row if it is live and never had a conversation
  record SESSION --transcript T --why clear|resume|start [--tmachine M]      append a conversation to the row (an id, a unique id prefix of 8+
                                                                             characters, or the live row's name); the same T twice is a no-op;
                                                                             an unknown SESSION is an error (exit 1, nothing written)
  tag SESSION [--project P] [--role front|back] [--project-key P] [--dry-run]
                                                                             fill project/role of an existing live row (an id, a unique id prefix of
                                                                             8+ characters, or the live row's name); only the given fields change;
                                                                             a retired row, an unknown SESSION or a bad role is an error (exit 1,
                                                                             nothing written). The row has no separate project_key (the published
                                                                             file derives it from project), so --project-key P sets project
  list [--all] [--json]                                                      the registry, read-only
  resolve REF [--live] [--json]                                              phase 3, read-only: REF is a session id (or a unique prefix of 8+
                                                                             characters), a transcript id, a name, an alias or role:<project>/<role>.
                                                                             Exit 0 found, 1 none (or the file unreadable), 2 ambiguous (the candidates
                                                                             listed); never picks among several
  transcript REF [--json]                                                    read-only: where the conversations of a session are on disk (needs
                                                                             --projects DIR, the CLI's projects directory): the current one first,
                                                                             then the earlier ones, with each file's path; the same exit codes as resolve
  relane [--dry-run]                                                         every row (live and retired) whose lane is a renamed lane's old name takes the
                                                                             current one (awsplatform -> aws-platform); prints how many; idempotent
  migrate --map F [--lanes F] [--models F] [--renames F] [--dry-run]         one row per pane-map row that has no live row
  check --map F [--lanes F] [--models F] [--dry-run]                         drift between the registry and the pane map: report, repair
"""
import argparse, datetime, glob, json, os, shutil, sys, tempfile, uuid
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))   # the helpers run with -I -S: the script's folder is not on the path by itself
import lanewords   # the lane words (lib/lanewords.py): an old word is read as the lane's current code

# side, side_origin, side_item, side_at: a side session (spawn --side, docs/side-sessions.md) marks its row "1" with the agent it was
# forked from, the board item it is about and when it started; unpublished (EXPORT_KEYS leaves them out)
# spawned_by: the session that started a throwaway (no project, no role, not a side session), written by spawn; `sala op retire NAME
# --from CALLER` takes no --words only when this is CALLER (lib/op.sh); unpublished too
# throwaway: "1" on a row a bare `sala spawn` made (no project, no role, no side flag); `sala op retire NAME --from
# ANY` takes no --words for a row that carries it, whoever started it (lib/op.sh); unpublished too. Cleared by `set`/`tag` the moment the row gets a
# project, a role or a side mark, so a tag never outlives the row being a throwaway.
FIELDS = ("lane", "model", "effort", "project", "role", "side", "side_origin", "side_item", "side_at", "spawned_by", "throwaway")
UNTAGGING = ("project", "role", "side")   # a non-empty value for one of these ends the row's life as a throwaway
SETTABLE = FIELDS + ("cwd", "pane")
# a lane that was renamed (Mon Oct 26th 2026: awsplatform -> aws-platform; Sun Nov 1st: max -> subscription-1, team -> subscription-2): a
# registry row written before still says the old word; it is read as the lane's current code on the way in (mint, set, check) and on the
# way out (the published file, the list), and written in the current code when a row is written. Only `relane` rewrites a stored row, and
# only for the lanes in MIGRATED (the awsplatform migration): max and team rows are never rewritten in place.
norm_lane = lanewords.norm_lane
MIGRATED = {"awsplatform": "aws-platform"}


def migrated_lane(v):
    return MIGRATED.get(v, v) if isinstance(v, str) else v


class RegistryError(Exception):
    pass


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class Registry:
    def __init__(self, a):
        self.path, self.log, self.history = a.file, a.log, a.history
        self.keep, self.caller, self.machine = a.keep, a.caller, a.machine
        self.data = None
        self.dirty = False
        self.lines = []

    # -- reading and writing the file ------------------------------------------------------------------------------
    def load(self):
        if not os.path.exists(self.path) or os.path.getsize(self.path) == 0:
            self.data = {"schema": 1, "sessions": {}}
            return self
        try:
            with open(self.path, encoding="utf-8") as f:
                d = json.load(f)
        except Exception as e:  # a corrupt file is never overwritten: the caller gets the reason, the file stays as it is
            raise RegistryError("%s is not readable JSON (%s) - left as it is; restore a copy from %s or delete it" % (self.path, e, self.history))
        if not isinstance(d, dict) or not isinstance(d.get("sessions"), dict):
            raise RegistryError("%s has no \"sessions\" object - left as it is" % self.path)
        self.data = d
        return self

    def save(self):
        if not self.dirty:
            return
        d = os.path.dirname(self.path) or "."
        os.makedirs(d, exist_ok=True)
        rows = sorted(self.data["sessions"].values(), key=lambda r: (r.get("created") or "", r.get("name") or "", r["id"]))
        self.data["sessions"] = {r["id"]: r for r in rows}
        self.data["schema"] = 1
        self.data["written"] = now()
        fd, tmp = tempfile.mkstemp(prefix=os.path.basename(self.path) + ".", dir=d)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(self.data, f, indent=2, ensure_ascii=False)
                f.write("\n")
                f.flush()
                os.fsync(f.fileno())
            self.history_copy()
            os.replace(tmp, self.path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
        self.dirty = False

    def history_copy(self):  # the file as it was, before it is replaced (like the pane map's map-history/); older than KEEP days pruned
        if not self.history or not os.path.exists(self.path) or os.path.getsize(self.path) == 0:
            return
        try:
            os.makedirs(self.history, exist_ok=True)
            ts = datetime.datetime.now().strftime("%Y%m%dT%H%M%S")
            dst = os.path.join(self.history, "sessions.%s.json" % ts)
            if os.path.exists(dst):
                dst = os.path.join(self.history, "sessions.%s.%d.json" % (ts, os.getpid()))
            shutil.copy2(self.path, dst)
            cutoff = datetime.datetime.now().timestamp() - self.keep * 86400
            for n in os.listdir(self.history):
                p = os.path.join(self.history, n)
                if n.startswith("sessions.") and n.endswith(".json") and os.path.getmtime(p) < cutoff:
                    os.unlink(p)
        except OSError:
            pass  # a history copy that cannot be made never stops the write

    def note(self, op, session, rid, detail):  # one line per change, buffered: written only once the file is
        self.lines.append("\t".join([datetime.datetime.now().astimezone().isoformat(timespec="seconds"), op, session or "-", rid or "-", detail, self.caller]))

    def flush_log(self):
        if not self.lines or not self.log:
            return
        try:
            os.makedirs(os.path.dirname(self.log) or ".", exist_ok=True)
            with open(self.log, "a", encoding="utf-8") as f:
                f.write("\n".join(self.lines) + "\n")
        except OSError:
            pass
        self.lines = []

    # -- rows ---------------------------------------------------------------------------------------------------------
    @property
    def rows(self):
        return self.data["sessions"]

    def live(self, name=None, pane=None):  # the live row for a name (first), else for a pane; the newest if more than one
        best = None
        for key, val in (("name", name), ("pane", pane)):
            if not val:
                continue
            c = [r for r in self.rows.values() if r.get("state") == "live" and r.get(key) == val]
            if c:
                c.sort(key=lambda r: r.get("created") or "")
                best = c[-1]
                break
        return best

    def mint(self, name, pane, uuid_, cwd, why, **fields):
        rid = str(uuid.uuid4())
        row = {"id": rid, "name": name, "project": None, "role": None, "lane": None, "model": None, "effort": None,
               "side": None, "side_origin": None, "side_item": None, "side_at": None, "spawned_by": None, "throwaway": None, "pane": pane or name, "cwd": cwd or None, "machine": self.machine, "created": now(), "state": "live",
               "aliases": [], "transcripts": []}
        for k in FIELDS:
            if fields.get(k) not in (None, ""):
                row[k] = norm_lane(fields[k]) if k == "lane" else fields[k]
        if uuid_:
            row["transcripts"].append({"id": uuid_, "machine": self.machine, "at": row["created"], "why": why})
        self.rows[rid] = row
        self.dirty = True
        return row

    def renamed(self, row, new, *also):  # the row takes a new name; the names it had (and any in `also`) are kept as aliases
        for old in (row["name"],) + also:
            if old and old != new and old not in row["aliases"]:
                row["aliases"].append(old)
        if new in row["aliases"]:  # renamed back to an old name: it is the name now, not an alias
            row["aliases"].remove(new)
        row["name"] = new

    def retire_row(self, row, why):
        row["state"] = "retired"
        row["retired_at"] = now()
        self.dirty = True
        self.note("retire", row["name"], row["id"], why)


def nz(v):
    return None if v in (None, "", "-") else v


# -- the commands ---------------------------------------------------------------------------------------------------------
def cmd_dual(R, a):
    op = a.args[0]
    if op in ("add", "adopt"):
        sess, uuid_, name, cwd = (a.args[1:5] + ["", "", "", ""])[:4]
        name = name or sess
        row = R.live(name, sess)
        if row is None:
            row = R.mint(name, sess, uuid_, cwd, op, lane=a.lane, model=a.model, effort=a.effort)
            R.note(op, sess, row["id"], "minted %s (%s)" % (name, uuid_))
            return
        before = json.dumps(row, sort_keys=True)
        if row["name"] != name:
            R.renamed(row, name)
        row["pane"] = sess
        if cwd:
            row["cwd"] = cwd
        if uuid_ and uuid_ not in [t["id"] for t in row["transcripts"]]:
            row["transcripts"].append({"id": uuid_, "machine": R.machine, "at": now(), "why": op})
        if json.dumps(row, sort_keys=True) != before:
            R.dirty = True
            R.note(op, sess, row["id"], "reused %s (%s)" % (name, uuid_))
    elif op == "rename":
        old, new, uuid_, name, cwd = (a.args[1:6] + ["", "", "", "", ""])[:5]
        name = name or new
        row = R.live(old, old)
        for other in [r for r in R.rows.values() if r.get("state") == "live" and r is not row and r.get("name") == name]:
            R.retire_row(other, "superseded by the rename of %s to %s" % (old, name))  # one live row per name
        if row is None:
            row = R.mint(name, new, uuid_, cwd, "adopt", lane=a.lane, model=a.model, effort=a.effort)  # the registry had no row for it: made from the map's
            R.renamed(row, name, old)
            R.note("rename", old, row["id"], "%s -> %s (no row for it; minted)" % (old, name))
            return
        R.renamed(row, name, old)
        row["pane"] = new
        if cwd:
            row["cwd"] = cwd
        R.dirty = True
        R.note("rename", old, row["id"], "%s -> %s" % (old, name))
    elif op == "retire":
        sess, name = (a.args[1:3] + ["", ""])[:2]
        row = R.live(name or sess, sess) or R.live(sess, None)
        if row is None:
            return
        R.retire_row(row, "retired")
    else:
        raise RegistryError("unknown dual op '%s'" % op)


def cmd_set(R, a):
    sess, pairs = a.args[0], a.args[1:]
    row = R.live(sess, sess)
    if row is None:
        if not a.mint:
            R.note("set", sess, None, "no live row, nothing to set (%s)" % " ".join(pairs))
            return
        uuid_, name, cwd, pane = (a.mint.split(",") + ["", "", "", ""])[:4]
        row = R.mint(name or sess, pane or sess, uuid_, cwd, "adopt")
        R.note("mint", sess, row["id"], "minted by a %s write" % pairs[0].split("=")[0])
    ch = []
    for p in pairs:
        k, _, v = p.partition("=")
        if k not in SETTABLE:
            raise RegistryError("cannot set '%s'" % k)
        v = nz(v)
        if k == "lane":
            v = norm_lane(v)
        if row.get(k) != v:
            ch.append("%s %s -> %s" % (k, row.get(k), v))
            row[k] = v
    if row.get("throwaway") and any(row.get(k) for k in UNTAGGING):   # the row is an agent or a side session now: no longer a throwaway
        ch.append("throwaway %s -> None" % row["throwaway"])
        row["throwaway"] = None
    if ch:
        R.dirty = True
        R.note("set", sess, row["id"], "; ".join(ch))


def cmd_relane(R, a):
    n = 0
    for r in R.rows.values():
        if isinstance(r.get("lane"), str) and migrated_lane(r["lane"]) != r["lane"]:
            n += 1
            if not a.dry_run:
                R.note("set", r.get("name") or "-", r.get("id"), "lane %s -> %s (the lane was renamed)" % (r["lane"], migrated_lane(r["lane"])))
                r["lane"] = migrated_lane(r["lane"])
                R.dirty = True
    print("%d row(s) %s" % (n, "would change" if a.dry_run else "changed"))


WHYS = ("clear", "resume", "start")   # `record`: what made the conversation (a /clear, a resume, a fresh start); add/adopt/import are the writers' own


def cmd_prepare(R, a):
    """spawn, before the session exists: its registry id, so the pane can be given it (SALA_SESSION_ID) and its own hooks can name the
    row. The live row of the name is reused (one live row per name); else a row without a conversation is made, and the conversation
    of the pane's first claude lands on it through ledger_write's add (which reuses a live row by name)."""
    name, pane, cwd = (a.args[:3] + ["", "", ""])[:3]
    if not name:
        raise RegistryError("prepare needs a NAME")
    row = R.live(name, pane or name)
    if row is None:
        row = R.mint(name, pane or name, "", cwd, "spawn", lane=a.lane, model=a.model, effort=a.effort)
        R.note("prepare", name, row["id"], "minted %s for a spawn" % name)
    print(row["id"])


def cmd_abandon(R, a):
    """spawn failed before its claude was up: drop the row `prepare` made. Only a live row that never had a conversation goes; a row
    that has one (a reused row, a spawn that got far enough to be mapped) is kept and `sessions --check` judges it."""
    rid = a.args[0] if a.args else ""
    row = R.rows.get(rid)
    if row is None or row.get("state") != "live" or row.get("transcripts"):
        return
    del R.rows[rid]
    R.dirty = True
    R.note("abandon", row["name"], rid, "dropped: the spawn did not come up")


def find_session(R, ref):  # a registry id, else the live row's name, else a unique id prefix of 8+ characters (`sala sessions` lists 8)
    if ref in R.rows:
        return R.rows[ref]
    named = R.live(ref, None)
    if named is not None:
        return named
    if len(ref) >= 8 and all(c in "0123456789abcdef-" for c in ref):
        c = [r for i, r in R.rows.items() if i.startswith(ref)]
        if len(c) == 1:
            return c[0]
        if len(c) > 1:
            raise RegistryError("'%s' matches %d sessions (%s): give more of the id" % (ref, len(c), ", ".join(x["id"][:13] for x in c)))
    raise RegistryError("no session '%s' (not an id, not the name of a live session): nothing recorded" % ref)


def cmd_record(R, a):
    """An explicit fresh start (the SessionStart hook's clear, resume, start; unpark's resume): the conversation joins the row's grow-only
    list. Idempotent: a conversation the row already lists (any `why`) changes nothing."""
    if not a.args:
        raise RegistryError("record needs a session id or name")
    if not a.transcript:
        raise RegistryError("record needs --transcript <claude session id>")
    if a.why not in WHYS:
        raise RegistryError("record needs --why %s, not '%s'" % ("|".join(WHYS), a.why or ""))
    row = find_session(R, a.args[0])
    if a.transcript in [t.get("id") for t in row.get("transcripts", [])]:
        return
    row.setdefault("transcripts", []).append({"id": a.transcript, "machine": a.tmachine or R.machine, "at": now(), "why": a.why})
    R.dirty = True
    R.note("record", row["name"], row["id"], "%s (%s)" % (a.transcript, a.why))


ROLES = ("front", "back")   # `tag`: the role vocabulary of stackshot-contracts.md interface 19 (spawn --role takes the same two)


def cmd_tag(R, a):
    """Fill `project` and/or `role` of an existing live row (a row made without `spawn --project --role`, an adopted one). Only the given
    fields are written. `project_key` is not a stored field: export_doc derives it from `project`, so --project-key is the same field
    under the published name (both given and different is an error)."""
    if len(a.args) != 1:
        raise RegistryError("tag needs exactly one session id or name")
    proj, pkey, role = a.project, a.project_key, a.role
    if proj is not None and pkey is not None and proj != pkey:
        raise RegistryError("--project '%s' and --project-key '%s' differ: the row has one value (project_key is derived from project)" % (proj, pkey))
    if proj is None:
        proj = pkey
    if proj is None and role is None:
        raise RegistryError("tag needs --project, --role or --project-key")
    if proj is not None and (not proj.strip() or any(c.isspace() or ord(c) < 32 for c in proj)):
        raise RegistryError("--project needs a gbrain page key without spaces (for example projects/salamander), not '%s'" % proj)
    if role is not None and role not in ROLES:
        raise RegistryError("--role must be %s, not '%s'" % (" or ".join(ROLES), role))
    row = find_session(R, a.args[0])
    if row.get("state") != "live":
        raise RegistryError("session '%s' (%s) is retired: a retired row is not tagged" % (row.get("name"), row["id"]))
    ch = []
    for k, v in (("project", proj), ("role", role)):
        if v is not None and row.get(k) != v:
            ch.append("%s %s -> %s" % (k, row.get(k), v))
            if not a.dry_run:
                row[k] = v
    if row.get("throwaway") and ch:   # a tagged row that gets a project or a role is no throwaway any more
        ch.append("throwaway %s -> None" % row["throwaway"])
        if not a.dry_run:
            row["throwaway"] = None
    if not ch:
        print("sessions tag: %s (%s) already has that: nothing changed" % (row["name"], row["id"][:8]))
        return
    print("sessions tag: %s %s (%s): %s" % ("would tag" if a.dry_run else "tagged", row["name"], row["id"][:8], "; ".join(ch)))
    if not a.dry_run:
        R.dirty = True
        R.note("tag", row["name"], row["id"], "; ".join(ch))
    p2, r2 = proj or row.get("project"), role or row.get("role")
    if p2 and r2:
        same = [x["name"] for x in R.rows.values() if x is not row and x.get("state") == "live" and x.get("project") == p2 and x.get("role") == r2]
        if same:
            print("note: %s also fills role:%s/%s, so resolving it is ambiguous until one of them is retagged" % (", ".join(same), p2, r2))


# -- phase 3: the published file and the resolver (both read-only) ------------------------------------------------------
EXPORT_KEYS = ("id", "name", "aliases", "project", "project_key", "role", "lane", "model", "effort", "pane", "cwd",
               "state", "created", "retired_at", "transcripts")


def export_doc(path, machine, written):
    """The document the heartbeat publishes as <fleet store>/<letter>/session-registry.json (docs/session-registry.md, phase 3).
    Reads `path` and raises RegistryError when it is missing or not a registry: the caller then keeps the last good file.
    project is the row's project value (the page key until stackshot has ids), project_key the same value."""
    if not os.path.exists(path):
        raise RegistryError("%s does not exist" % path)
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
    except Exception as e:
        raise RegistryError("%s is not readable JSON (%s)" % (path, e))
    if not isinstance(d, dict) or not isinstance(d.get("sessions"), dict):
        raise RegistryError("%s has no \"sessions\" object" % path)
    rows = []
    for r in d["sessions"].values():
        if not isinstance(r, dict) or not r.get("id"):
            continue
        o = dict(r)
        o["lane"] = norm_lane(r.get("lane"))   # the published file carries the lane's current name, whatever the row still says
        o["project_key"] = r.get("project")
        o["aliases"] = list(r.get("aliases") or [])
        o["transcripts"] = [{"id": t.get("id"), "machine": t.get("machine"), "at": t.get("at"), "why": t.get("why")}
                            for t in (r.get("transcripts") or []) if isinstance(t, dict)]
        rows.append({k: o.get(k) for k in EXPORT_KEYS})
    rows.sort(key=lambda r: (r.get("created") or "", r.get("name") or "", r["id"]))
    return {"schema": 1, "machine": machine, "written": written, "sessions": {r["id"]: r for r in rows}}


class Unresolved(RegistryError):
    """`kind` is "none" (nothing matches) or "ambiguous" (several rows match: `candidates` lists them; nothing is ever picked)."""
    def __init__(self, kind, msg, candidates=()):
        RegistryError.__init__(self, msg)
        self.kind, self.candidates = kind, list(candidates)


def _hex_prefix(ref):
    return len(ref) >= 8 and all(c in "0123456789abcdef-" for c in ref)


def resolve(rows, ref, live_only=False):
    """The one row `ref` names, or Unresolved. `rows`: the registry's id -> row dict. The kinds are tried in order, and the first that
    matches anything decides: an exact session id; a transcript id (any row listing it); a unique id prefix of 8+ characters; a name
    or an alias (together, so a retired row's old name that a live row now carries is two matches); `role:<project>/<role>` (live rows).
    More than one match is `ambiguous`, never a pick; `live_only` drops retired rows first, which is the only thing that narrows a
    name that a retired and a live row share. Read-only."""
    ref = (ref or "").strip()
    if not ref:
        raise Unresolved("none", "no reference given")
    pool = [r for r in rows.values() if not live_only or r.get("state") == "live"]

    def one(found, what):
        if len(found) == 1:
            return found[0]
        found = sorted(found, key=lambda r: (r.get("created") or "", r["id"]))
        raise Unresolved("ambiguous", "ambiguous: %s '%s' matches %d sessions (%s)%s" % (
            what, ref, len(found), ", ".join(r["id"] for r in found),
            "" if live_only else "; --live keeps only the live ones"), found)

    if ref.startswith("role:"):
        proj, sep, role = ref[5:].rpartition("/")
        if not sep or not proj or not role:
            raise Unresolved("none", "'%s' is not role:<project>/<role> (for example role:projects/salamander/back)" % ref)
        found = [r for r in rows.values() if r.get("state") == "live" and r.get("project") == proj and r.get("role") == role]
        if not found:
            raise Unresolved("none", "no live session fills %s as %s" % (proj, role))
        return one(found, "role")
    found = [r for r in pool if r.get("id") == ref]
    if found:
        return found[0]
    found = [r for r in pool if ref in [t.get("id") for t in (r.get("transcripts") or [])]]
    if found:
        return one(found, "transcript")
    if _hex_prefix(ref):
        found = [r for r in pool if (r.get("id") or "").startswith(ref)]
        if found:
            return one(found, "id prefix")
    found = [r for r in pool if r.get("name") == ref or ref in (r.get("aliases") or [])]
    if found:
        return one(found, "name")
    raise Unresolved("none", "no %ssession '%s' (not an id, a transcript id, a name, an alias or role:<project>/<role>)" % ("live " if live_only else "", ref))


def cmd_resolve(R, a):
    if len(a.args) != 1:
        raise RegistryError("resolve needs exactly one reference")
    try:
        row = resolve(R.rows, a.args[0], a.live)
    except Unresolved as u:
        if a.json:
            print(json.dumps({"error": u.kind, "ref": a.args[0], "candidates": [r["id"] for r in u.candidates]}, ensure_ascii=False))
        print("sessions resolve: %s" % u, file=sys.stderr)
        for r in u.candidates:
            print("  %s  %s  %s  %s  %s" % (r["id"], r.get("name") or "-", r.get("state") or "-", r.get("project") or "-", r.get("role") or "-"), file=sys.stderr)
        return 2 if u.kind == "ambiguous" else 1
    if a.json:
        print(json.dumps(row, indent=2, ensure_ascii=False))
        return 0
    print("id:      %s" % row["id"])
    print("name:    %s" % (row.get("name") or "-"))
    print("state:   %s%s" % (row.get("state") or "-", " (retired %s)" % row["retired_at"] if row.get("state") == "retired" and row.get("retired_at") else ""))
    print("project: %s" % (row.get("project") or "-"))
    print("role:    %s" % (row.get("role") or "-"))
    print("pane:    %s" % (row.get("pane") or "-"))
    return 0


def transcript_file(projects, tid):
    """The file of one claude session id under the CLI's projects directory (the newest when two projects hold it, as transcript_for_uuid
    does), or None: not on this box, or never written."""
    hits = sorted(glob.glob(os.path.join(projects, "*", tid + ".jsonl")), key=os.path.getmtime, reverse=True) if projects and tid else []
    return hits[0] if hits else None


def cmd_transcript(R, a):
    """`sessions transcript <ref> [--json]`, read-only like resolve: where the conversations of a session are on disk, the current one
    (the row's last) first, then the earlier ones, each with the file's path ("-" / null when the file is not on this box). A live row
    wins over a retired one of the same name; several live rows are ambiguous (exit 2), nothing none (exit 1)."""
    if len(a.args) != 1:
        raise RegistryError("transcript needs exactly one reference")
    ref = a.args[0]
    try:
        try:
            row = resolve(R.rows, ref, True)
        except Unresolved as u:
            if u.kind != "none":
                raise
            row = resolve(R.rows, ref)
    except Unresolved as u:
        if a.json:
            print(json.dumps({"error": u.kind, "ref": ref, "candidates": [r["id"] for r in u.candidates]}, ensure_ascii=False))
        print("sessions transcript: %s" % u, file=sys.stderr)
        for r in u.candidates:
            print("  %s  %s  %s" % (r["id"], r.get("name") or "-", r.get("state") or "-"), file=sys.stderr)
        return 2 if u.kind == "ambiguous" else 1
    ts = list(row.get("transcripts") or [])
    out = []
    for i, t in enumerate(reversed(ts)):
        out.append({"id": t.get("id"), "path": transcript_file(a.projects, t.get("id")), "current": i == 0,
                    "machine": t.get("machine"), "at": t.get("at"), "why": t.get("why")})
    if a.json:
        print(json.dumps({"id": row["id"], "name": row.get("name"), "state": row.get("state"), "transcripts": out}, indent=2, ensure_ascii=False))
        return 0
    print("%s (%s, %s): %d conversation%s" % (row.get("name") or "-", row["id"][:8], row.get("state") or "-", len(out), "" if len(out) == 1 else "s"))
    for t in out:
        print("%s  %s  %s  %s" % ("current" if t["current"] else "earlier", t["path"] or "(not on this box)", t["at"] or "-", t["why"] or "-"))
    return 0


def table(rows, cols):
    w = [max(len(str(c)), *(len(str(r[i])) for r in rows)) if rows else len(str(c)) for i, c in enumerate(cols)]
    out = ["  ".join(str(c).ljust(w[i]) for i, c in enumerate(cols)).rstrip()]
    for r in rows:
        out.append("  ".join(str(x).ljust(w[i]) for i, x in enumerate(r)).rstrip())
    return "\n".join(out)


def cmd_list(R, a):
    rows = [r for r in R.rows.values() if a.all or r.get("state") == "live"]
    rows.sort(key=lambda r: (r.get("name") or "", r.get("created") or ""))
    if a.json:
        print(json.dumps({"schema": 1, "sessions": rows}, indent=2, ensure_ascii=False))
        return
    if not rows:
        print("the session registry is empty (%s)" % R.path)
        return
    out = []
    for r in rows:
        me = "%s%s" % (r.get("model") or "-", "/" + r["effort"] if r.get("effort") else "")
        out.append((r["id"][:8], r.get("name") or "-", r.get("state") or "-", norm_lane(r.get("lane")) or "-", me, r.get("project") or "-",
                    r.get("role") or ("side" if r.get("side") else "-"),   # a side session (spawn --side) has no role: its column says so
                    len(r.get("transcripts") or []), ",".join(r.get("aliases") or []) or "-"))
    print(table(out, ("ID", "NAME", "STATE", "LANE", "MODEL", "PROJECT", "ROLE", "TRANSCRIPTS", "ALIASES")))
    n = sum(1 for r in R.rows.values() if r.get("state") == "live")
    print("%d live, %d retired (%s)" % (n, len(R.rows) - n, R.path))


def read_map(path):  # the pane map: tmux_session \t uuid \t name \t cwd
    rows = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                p = line.rstrip("\n").split("\t")
                if p and p[0]:
                    rows.append((p + ["", "", "", ""])[:4])
    except OSError:
        pass
    return rows


def read_tsv(path):
    d = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                p = line.rstrip("\n").split("\t")
                if len(p) >= 2 and p[0]:
                    d[p[0]] = p[1:]
    except OSError:
        pass
    return d


def renames_aliases(path, name, uuid_):  # every earlier name of a conversation, from salamander-renames.jsonl ({uuid, from, to})
    recs = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                try:
                    r = json.loads(line)
                    if isinstance(r, dict) and r.get("from") and r.get("to"):
                        recs.append(r)
                except ValueError:
                    pass
    except OSError:
        return []
    names, out = {name}, []
    changed = True
    while changed:
        changed = False
        for r in recs:
            if (r["to"] in names or (uuid_ and r.get("uuid") == uuid_)) and r["from"] not in names:
                names.add(r["from"])
                out.append(r["from"])
                changed = True
    return out


def table_fields(lanes, models, name):
    lane = norm_lane(nz((lanes.get(name) or [""])[0]))
    m = models.get(name) or ["", ""]
    return {"lane": lane, "model": nz(m[0]), "effort": nz(m[1] if len(m) > 1 else "")}


def cmd_migrate(R, a):
    lanes, models = read_tsv(a.lanes), read_tsv(a.models)
    n = made = have = 0
    for sess, uuid_, name, cwd in read_map(a.map):
        n += 1
        name = name or sess
        if R.live(name, sess):
            have += 1
            continue
        f = table_fields(lanes, models, name)
        al = renames_aliases(a.renames, name, uuid_) if a.renames else []
        if a.dry_run:
            print("would mint\t%s\tpane=%s\tuuid=%s\tcwd=%s\tlane=%s\tmodel=%s\teffort=%s\taliases=%s" % (
                name, sess, uuid_, cwd or "-", f["lane"] or "-", f["model"] or "-", f["effort"] or "-", ",".join(al) or "-"))
        else:
            row = R.mint(name, sess, uuid_, cwd, "import", **f)
            row["aliases"] = [x for x in al if x != name]
            R.note("migrate", sess, row["id"], "imported %s (%s)" % (name, uuid_))
        made += 1
    print("sessions migrate%s: %d pane-map rows, %d %s, %d already have a live registry row" % (
        " --dry-run" if a.dry_run else "", n, made, "to mint" if a.dry_run else "minted", have))


def cmd_check(R, a):
    """Drift between the registry and the pane map, the kind a kill between ledger_write's two writes leaves.
    Repairs only the registry (the pane map is the authority until phase 4); a transcript the map has that the row lacks
    is only reported (phase 2: an explicit signal, `record`, appends one; check never guesses)."""
    lanes, models = read_tsv(a.lanes), read_tsv(a.models)
    mp = read_map(a.map)
    by_name = {}
    for sess, uuid_, name, cwd in mp:
        by_name[name or sess] = (sess, uuid_, cwd)
    problems, fixed = [], []

    def act(msg, fn):
        if a.dry_run:
            problems.append(msg)
            return
        fn()
        fixed.append(msg)

    lives = [r for r in R.rows.values() if r.get("state") == "live"]
    seen = {}
    for r in lives:  # two live rows for one name: report, never guess which one
        seen.setdefault(r["name"], []).append(r)
    for name, rs in seen.items():
        if len(rs) > 1:
            problems.append("%s has %d live rows (%s): left for a person" % (name, len(rs), ", ".join(x["id"][:8] for x in rs)))
    orphans = [r for r in lives if r["name"] not in by_name and len(seen[r["name"]]) == 1]
    unmatched = {n for n in by_name if not R.live(n, by_name[n][0])}
    for r in list(orphans):  # a row whose conversation sits in a map row of an unregistered name: a rename the registry missed
        ids = {t["id"] for t in r.get("transcripts", [])}
        for n in sorted(unmatched):
            sess, uuid_, cwd = by_name[n]
            if uuid_ and uuid_ in ids:
                def f(r=r, n=n, sess=sess, cwd=cwd):
                    was = r["name"]
                    R.renamed(r, n)
                    r["pane"] = sess
                    if cwd:
                        r["cwd"] = cwd
                    R.dirty = True
                    R.note("check", n, r["id"], "repaired: renamed from %s" % was)
                act("%s: the registry row %s still has the name before the rename (now %s)" % (n, r["id"][:8], n), f)
                unmatched.discard(n)
                orphans.remove(r)
                break
    for r in orphans:  # a retire the registry missed
        act("%s: live in the registry, no pane-map row (retire not recorded)" % r["name"], lambda r=r: R.retire_row(r, "repaired: no pane-map row"))
    for n in sorted(unmatched):  # an add the registry missed
        sess, uuid_, cwd = by_name[n]
        def f(n=n, sess=sess, uuid_=uuid_, cwd=cwd):
            row = R.mint(n, sess, uuid_, cwd, "import", **table_fields(lanes, models, n))
            R.note("check", n, row["id"], "repaired: minted from the pane-map row")
        act("%s: in the pane map, no live registry row" % n, f)
    for r in [x for x in R.rows.values() if x.get("state") == "live"]:  # the tables' fields against the row's
        if r["name"] not in by_name:
            continue
        want = table_fields(lanes, models, r["name"])
        diff = {k: v for k, v in want.items() if r.get(k) != v}
        if diff:
            def f(r=r, diff=diff):
                r.update(diff)
                R.dirty = True
                R.note("check", r["name"], r["id"], "repaired: " + ", ".join("%s=%s" % kv for kv in diff.items()))
            act("%s: %s differ from lanes.tsv/models.tsv" % (r["name"], ", ".join(sorted(diff))), f)
        sess, uuid_, cwd = by_name[r["name"]]
        if uuid_ and uuid_ not in [t["id"] for t in r["transcripts"]]:
            print("note: %s: the pane map's conversation %s is not in the row's transcripts (only reported)" % (r["name"], uuid_))
    for m in fixed:
        print("repaired: " + m)
    for m in problems:
        print(("would repair: " if a.dry_run else "UNRESOLVED: ") + m)
    live_n = sum(1 for r in R.rows.values() if r.get("state") == "live")
    if not fixed and not problems:
        print("sessions --check: consistent (%d pane-map rows, %d live registry rows)" % (len(mp), live_n))
        return 0
    print("sessions --check: %s" % ("%d repaired" % len(fixed) if fixed and not problems else "%d to repair" % len(problems) if a.dry_run else "%d repaired, %d left" % (len(fixed), len(problems))))
    return 1 if problems else 0


def main():
    p = argparse.ArgumentParser(prog="sessions.py")
    p.add_argument("--file", required=True)
    p.add_argument("--log", default="")
    p.add_argument("--history", default="")
    p.add_argument("--keep", type=int, default=30)
    p.add_argument("--caller", default="")
    p.add_argument("--machine", default="")
    p.add_argument("cmd", choices=["dual", "set", "prepare", "abandon", "record", "tag", "list", "resolve", "transcript", "migrate", "check", "relane"])
    p.add_argument("args", nargs="*")
    p.add_argument("--lane"); p.add_argument("--model"); p.add_argument("--effort")
    p.add_argument("--transcript"); p.add_argument("--why"); p.add_argument("--tmachine", default="")
    p.add_argument("--mint"); p.add_argument("--all", action="store_true"); p.add_argument("--json", action="store_true")
    p.add_argument("--live", action="store_true"); p.add_argument("--projects", default="")
    p.add_argument("--project"); p.add_argument("--role"); p.add_argument("--project-key", dest="project_key")
    p.add_argument("--dry-run", action="store_true", dest="dry_run")
    p.add_argument("--map"); p.add_argument("--lanes", default=""); p.add_argument("--models", default=""); p.add_argument("--renames", default="")
    a = p.parse_args()
    R = Registry(a)
    rc = 0
    if a.cmd in ("resolve", "transcript"):  # read-only to the letter: not even an error line in sessions.log
        try:
            return (cmd_resolve if a.cmd == "resolve" else cmd_transcript)(R.load(), a)
        except Exception as e:
            print("sessions %s: %s" % (a.cmd, e), file=sys.stderr)
            return 1
    try:
        R.load()
        if a.cmd == "dual":
            cmd_dual(R, a)
        elif a.cmd == "set":
            cmd_set(R, a)
        elif a.cmd == "prepare":
            cmd_prepare(R, a)
        elif a.cmd == "abandon":
            cmd_abandon(R, a)
        elif a.cmd == "record":
            cmd_record(R, a)
        elif a.cmd == "tag":
            cmd_tag(R, a)
        elif a.cmd == "list":
            cmd_list(R, a)
        elif a.cmd == "migrate":
            cmd_migrate(R, a)
        elif a.cmd == "relane":
            cmd_relane(R, a)
        elif a.cmd == "check":
            rc = cmd_check(R, a)
        if a.cmd in ("dual", "set", "prepare", "abandon", "record", "tag", "migrate", "check", "relane") and not getattr(a, "dry_run", False):
            R.save()
            R.flush_log()
    except Exception as e:
        R.lines = []
        R.note("error", a.args[1] if a.cmd == "dual" and len(a.args) > 1 else (a.args[0] if a.args else "-"), None, "%s %s failed: %s" % (a.cmd, " ".join(a.args[:2]), e))
        R.flush_log()
        print("sessions registry: %s" % e, file=sys.stderr)
        return 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
