"""Live Claude Code sessions (from ~/.claude/sessions/<pid>.json) and their roles (from stackshot).

Read-only: nothing here writes to tmux or to the session registry.
"""

from __future__ import annotations

import asyncio
import json
import mmap
import os
import re
import subprocess
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from . import scopes as SC
from .config import SHELL_SESSION, Settings
from .spend import normalize_model

ROLE_ORDER = {"front": 0, "back": 1}  # any other role (an old registry row) sorts after back
UNREGISTERED = "Unregistered"


@dataclass
class Session:
    pid: int
    session_id: str
    name: str
    cwd: str
    status: str
    tmux: str  # "session:@window.%pane"
    updated_at: int | None = None
    role: str | None = None
    project: str | None = None
    lane: str | None = None
    started_at: int | None = None  # the registry's startedAt: when this claude process started, epoch ms
    side: dict | None = None  # a quick (side) session's record, {"kind", "origin", "item"}; None for every other session
    parked_job: str | None = None  # the background job its conversation moved into (registry parkedJobId), else None
    agent_id: str | None = None  # sala's permanent id for the agent (sessions.json row id; outlives a rename, a recycle, a /clear), else None
    aliases: tuple[str, ...] = ()  # the names the agent had before (the registry row's aliases)

    @property
    def tmux_session(self) -> str:
        return self.tmux.split(":", 1)[0] if self.tmux else ""

    @property
    def pane_id(self) -> str | None:
        m = re.search(r"(%\d+)$", self.tmux or "")
        return m.group(1) if m else None

    def to_json(self) -> dict:
        out = {
            "pid": self.pid,
            "sessionId": self.session_id,
            "name": self.name,
            "cwd": self.cwd,
            "status": self.status,
            "tmux": self.tmux,
            "tmuxSession": self.tmux_session,
            "paneId": self.pane_id,
            "role": self.role,
            "project": self.project,
            "lane": self.lane,
            "updatedAt": self.updated_at,
            "startedAt": self.started_at,
        }
        if self.side:   # only a side session carries the key, so every other session's payload is as it was
            out["side"] = self.side
        if self.parked_job:   # likewise only a parked pane: the label reads "in background job <id>"
            out["parkedJob"] = self.parked_job
        if self.agent_id:     # the page keys the owner's saved order on it (a name changes, the id does not); absent: it keys on the name
            out["agentId"] = self.agent_id
            if self.aliases:
                out["aliases"] = list(self.aliases)
        return out


# sala's lanes (salamander lib/common.sh, proc_lane), in its order: an Agent SDK entrypoint is the sdk lane (the API
# credit), CLAUDE_CODE_USE_BEDROCK=1 the bedrock lane, CLAUDE_CODE_USE_ANTHROPIC_AWS=1 the aws-platform lane
# (Claude Platform on AWS; Bedrock is asked first, as the CLI's routing does), an API key in the environment
# is the api lane, a CLAUDE_CONFIG_DIR names a second login (subscription-2), none of these is the subscription-1 login in ~/.claude
# (the two had other names once: lanestate.RENAMED reads the old words, nothing here writes them). The two
# AWS flags are the whole test, as in sala (no key sits in those lanes' environment). The directories are sala's defaults.
LANE_DIRS = {"subscription-2": Path.home() / ".claude-team"}   # the second login's default config directory
# the lanes a new session can be spawned on (the New session form's list): the subscription-1 login, the second logins,
# the API key, the two AWS lanes (sala refuses one that cannot launch yet, and says why). Not sdk: its pane program only
# resumes a conversation (lib/spawn.sh refuses it; a session is spawned on another lane and moved with `sala lane sdk NAME`)
SPAWN_LANES = ("subscription-1", *LANE_DIRS, "api", "bedrock", "aws-platform")


def proc_lane(pid: int) -> str | None:
    """The lane a claude process runs on, read from its environment as `sala lane` does; None when unreadable."""
    try:
        env = Path(f"/proc/{pid}/environ").read_bytes().split(b"\0")
    except OSError:
        return None
    if any(e.startswith(b"CLAUDE_CODE_ENTRYPOINT=sdk-") for e in env):
        return "sdk"
    if b"CLAUDE_CODE_USE_BEDROCK=1" in env:
        return "bedrock"
    if b"CLAUDE_CODE_USE_ANTHROPIC_AWS=1" in env:
        return "aws-platform"
    if any(e.startswith(b"ANTHROPIC_API_KEY=") and len(e) > len(b"ANTHROPIC_API_KEY=") for e in env):
        return "api"
    cfg = next((e.split(b"=", 1)[1].decode(errors="replace") for e in env if e.startswith(b"CLAUDE_CONFIG_DIR=")), "")
    if not cfg:
        return "subscription-1"
    for lane, d in LANE_DIRS.items():
        if Path(cfg).resolve() == d.resolve():
            return lane
    return "other"


def proc_start(pid: int) -> str | None:
    """Field 22 of /proc/<pid>/stat (start time in clock ticks), as the CLI records it in procStart."""
    try:
        stat = Path(f"/proc/{pid}/stat").read_text()
    except OSError:
        return None
    # comm (field 2) may contain spaces and parens; split after the last ')'.
    rest = stat.rsplit(")", 1)[1].split()
    return rest[19] if len(rest) > 19 else None


def pid_alive(pid: int, recorded_start: str | None) -> bool:
    start = proc_start(pid)
    if start is None:
        return False
    # Guard against pid reuse when the registry recorded the process start time.
    return recorded_start is None or str(recorded_start) == start


def parent_pid(pid: int) -> int | None:
    try:
        stat = Path(f"/proc/{pid}/stat").read_text()
    except OSError:
        return None
    rest = stat.rsplit(")", 1)[1].split()
    return int(rest[1]) if len(rest) > 1 else None


def is_same_or_descendant(pid: int, ancestor: int, max_depth: int = 8) -> bool:
    cur: int | None = pid
    for _ in range(max_depth):
        if cur is None or cur <= 1:
            return False
        if cur == ancestor:
            return True
        cur = parent_pid(cur)
    return False


def live_tmux_names() -> dict[str, str]:
    """pane id -> the current name of its tmux session. The registry keeps the name from launch, so a rename
    (sala rename) would otherwise show the old one. {} if tmux cannot be asked."""
    try:
        out = subprocess.run(["tmux", "list-panes", "-a", "-F", "#{pane_id}\t#{session_name}"],
                             capture_output=True, text=True, timeout=3).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    return dict(line.split("\t", 1) for line in out.splitlines() if "\t" in line)


def _with_live_name(tmux: str, names: dict[str, str]) -> str:
    m = re.search(r"(%\d+)$", tmux or "")
    if not m or m.group(1) not in names or ":" not in tmux:
        return tmux
    return names[m.group(1)] + ":" + tmux.split(":", 1)[1]


def job_row(parked: str, rows: list[dict], own_pid: int) -> dict | None:
    """The registry row of the background job a pane's conversation moved into. CLI 2.1.312 writes `parkedJobId` (the short
    job id, 8 characters) on the pane's row and a second row, `kind` "bg", whose `jobId` is the same and whose `sessionId` is
    the job's conversation; older CLIs wrote the fork's whole uuid in parkedJobId. So: the row whose jobId is it, else the one
    whose sessionId is it or starts with it (a short id). Never the pane's own row. sala's lib/common.sh parked_job_pid_r reads
    the same fields the same way."""
    for d in rows:
        if d["pid"] != own_pid and d.get("jobId") == parked:
            return d
    for d in rows:
        sid = d.get("sessionId") or ""
        if d["pid"] != own_pid and sid and (sid == parked or (len(parked) >= 8 and sid.startswith(parked))):
            return d
    return None


def read_live_sessions(settings: Settings) -> list[Session]:
    """The live sessions, one row each. A conversation can be moved into a background job (the CLI's "← for agents" view):
    the pane's claude stays as a viewer (status "shell", `parkedJobId`) and the registry holds a second row, the job's, under
    the same name. They are ONE session: the pane's row carries the identity (pane, name) and is marked
    `parked_job`; its status is the job's (the viewer's own is always "shell"), its sessionId the job's conversation (the
    transcript and the model are read from there), and the job's row is not listed. A job with no pane row stays listed."""
    out: list[Session] = []
    names = live_tmux_names()
    rows: list[dict] = []
    for f in settings.sessions_dir.glob("*.json"):
        try:
            d = json.loads(f.read_text())
            d["pid"] = int(d["pid"])
        except (OSError, ValueError, KeyError, TypeError):
            continue
        if not pid_alive(d["pid"], d.get("procStart")):
            continue
        rows.append(d)
    jobs: dict[int, dict] = {}   # a parked pane's pid -> its job's row
    claimed: set[int] = set()    # the pids of job rows folded into a pane's
    for d in rows:
        parked = d.get("parkedJobId")
        if isinstance(parked, str) and parked and d.get("tmux"):
            job = job_row(parked, rows, d["pid"])
            if job is not None:
                jobs[d["pid"]] = job
                claimed.add(job["pid"])
    for d in rows:
        pid = d["pid"]
        if pid in claimed:
            continue
        parked = d.get("parkedJobId") if isinstance(d.get("parkedJobId"), str) and d.get("parkedJobId") else None
        job = jobs.get(pid)
        status, sid, updated = d.get("status", "unknown"), d.get("sessionId", ""), d.get("updatedAt")
        if job is not None:
            status = job.get("status", "unknown")
            sid = job.get("sessionId") or sid
            if isinstance(job.get("updatedAt"), int):
                updated = max(updated, job["updatedAt"]) if isinstance(updated, int) else job["updatedAt"]
            parked = job.get("jobId") or parked
        out.append(Session(
            pid=pid,
            session_id=sid,
            name=d.get("name") or f"pid-{pid}",
            cwd=d.get("cwd", ""),
            status=status,
            tmux=_with_live_name(d.get("tmux", ""), names),
            updated_at=updated,
            lane=proc_lane(pid),
            started_at=d.get("startedAt") if isinstance(d.get("startedAt"), int) else None,
            parked_job=parked,
        ))
    # the Shell drawer's tmux session is no Claude session: a registry row that points into it (a claude started by
    # hand inside it) is not listed either, so no list, count or send can ever aim at the owner's shell
    return [s for s in out if s.tmux_session != SHELL_SESSION]


# The model a pane runs NOW, for the sessions table. The transcript's latest reply alone lags: a session relaunched on a
# new model keeps showing the old one until it answers (panes kept showing the old model for an hour after a relaunch onto
# a newer one). So the sources, in order: the claude process's own command line (`--model`,
# `--effort`: sala puts both on every resume line, lib/common.sh resume_cmd), then sala's record for the session
# (models.tsv: what its next relaunch takes), then the latest reply. A CLI alias on the line (opus, sonnet) has no
# version, and the table must always show one, so it is resolved as the CLI resolves it:
# a reply of that family written after the process started (it also catches a /model switch within the family), else
# the process's ANTHROPIC_DEFAULT_<ALIAS>_MODEL, else the alias's default in the model catalog baked into the binary
# the process runs. Only when none of these answers does the row show the alias, marked "version unknown".
MODEL_FAMILIES = ("opus", "sonnet", "haiku", "fable")   # the CLI's aliases (sala's SALA_MODEL_FAMILIES)
ALIAS_RE = re.compile(r"([a-z]+)(\[1m\])?", re.I)       # opus, sonnet[1m]: a model name with no version


def parse_launch_flags(argv: list[str]) -> dict:
    """{"model", "effort"} from a claude command line (`--model x` or `--model=x`, the same for --effort), each only
    when present; the last occurrence wins, as the CLI's parser takes it."""
    out: dict[str, str] = {}
    for i, a in enumerate(argv):
        for flag in ("model", "effort"):
            if a == f"--{flag}" and i + 1 < len(argv) and argv[i + 1]:
                out[flag] = argv[i + 1]
            elif a.startswith(f"--{flag}=") and len(a) > len(flag) + 3:
                out[flag] = a[len(flag) + 3:]
    return out


def launch_flags(pid: int) -> dict:
    """The --model and --effort on the process's own command line (/proc/<pid>/cmdline); {} when unreadable."""
    try:
        raw = Path(f"/proc/{pid}/cmdline").read_bytes()
    except OSError:
        return {}
    return parse_launch_flags([a.decode(errors="replace") for a in raw.split(b"\0") if a])


_ENV_OVERRIDE = re.compile(rb"ANTHROPIC_DEFAULT_([A-Z]+)_MODEL=(.+)", re.S)


def model_env(pid: int) -> dict[str, str]:
    """The process's alias overrides, ANTHROPIC_DEFAULT_<ALIAS>_MODEL: alias (lowercase) -> model. Nothing else is read
    out of the environment. {} when unreadable."""
    try:
        env = Path(f"/proc/{pid}/environ").read_bytes().split(b"\0")
    except OSError:
        return {}
    out: dict[str, str] = {}
    for e in env:
        m = _ENV_OVERRIDE.fullmatch(e)
        if m:
            out[m.group(1).decode().lower()] = m.group(2).decode(errors="replace").strip()
    return out


# The catalog Claude Code embeds in its binary (2.1.29x), as plain bytes:
#   aliases:{opus:{default:"claude-opus-5-5",per_provider:{...}},sonnet:{...},...},defaults:{},best:"fable",
#   latest_per_family:{fable:"claude-fable-5-1",opus:"claude-opus-5-5",...}
# The binary is ~250 MB: it is mapped, not read, the one anchor found with mmap.find, and only a window before it parsed.
CATALOG_ANCHOR = b"latest_per_family:{"
CATALOG_WINDOW = 16 << 10   # how far before the anchor the aliases block may start
_CATALOG_ID = rb'"(claude-[A-Za-z0-9.\-\[\]]{1,80})"'
_ALIAS_ENTRY = re.compile(rb"([a-z][a-z0-9_]{0,31}):\{default:" + _CATALOG_ID)
_FAMILY_ENTRY = re.compile(rb"([a-z][a-z0-9_]{0,31}):" + _CATALOG_ID)


def parse_catalog(path: str | Path) -> dict:
    """{"aliases": {alias: first-party id}, "latest": {family: id}} from a Claude Code binary; {} when the file has no
    catalog (another program, an older or newer layout) or cannot be read."""
    try:
        with open(path, "rb") as f:
            if os.fstat(f.fileno()).st_size == 0:
                return {}
            with mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as m:
                pos = m.find(CATALOG_ANCHOR)
                for _ in range(8):   # the first anchor with a catalog around it; a stray match is skipped
                    if pos == -1:
                        break
                    got = _catalog_at(m, pos)
                    if got:
                        return got
                    pos = m.find(CATALOG_ANCHOR, pos + 1)
    except (OSError, ValueError):
        return {}
    return {}


def _catalog_at(m: mmap.mmap, pos: int) -> dict:
    body = pos + len(CATALOG_ANCHOR)
    end = m.find(b"}", body, body + 4096)
    latest = {k.decode(): v.decode() for k, v in _FAMILY_ENTRY.findall(m[body:end])} if end != -1 else {}
    window = m[max(0, pos - CATALOG_WINDOW):pos]
    start = window.rfind(b"aliases:{")
    aliases = {k.decode(): v.decode() for k, v in _ALIAS_ENTRY.findall(window[start:])} if start != -1 else {}
    return {"aliases": aliases, "latest": latest} if aliases or latest else {}


class CatalogCache:
    """parse_catalog of the binary a process runs (/proc/<pid>/exe, so a pane still on an older or since-deleted version
    gets that version's catalog), scanned once per binary for the server's lifetime: keyed by the file's device, inode,
    size and mtime. Each entry also names the binary ("binary": its file name, the CLI version)."""

    def __init__(self) -> None:
        self._by_file: dict[tuple, dict] = {}
        self._lock = threading.Lock()   # overview polls run in a threadpool: one scan per binary, not one per poll

    def for_pid(self, pid: int) -> dict:
        exe = f"/proc/{pid}/exe"
        try:
            st = os.stat(exe)
            name = os.readlink(exe)
        except OSError:
            return {}
        key = (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns)
        with self._lock:
            if key not in self._by_file:
                got = parse_catalog(exe)
                if got:
                    got["binary"] = Path(name.removesuffix(" (deleted)")).name
                self._by_file[key] = got
            return self._by_file[key]


def sala_models(path: Path) -> dict[str, dict]:
    """sala's models.tsv: tmux session -> {"model", "effort"} (no effort, "-": the transcript's is kept -> None).
    {} when the file is missing or unreadable; a malformed line is skipped."""
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return {}
    out: dict[str, dict] = {}
    for line in text.splitlines():
        parts = line.rstrip("\n").split("\t")
        if len(parts) < 2 or not parts[0] or not parts[1]:
            continue
        effort = parts[2] if len(parts) > 2 and parts[2] not in ("", "-") else None
        out[parts[0]] = {"model": parts[1], "effort": effort}
    return out


def _after_start(ts: object, started_at: int | None) -> bool:
    """Is the transcript line's ISO timestamp after the process start (epoch ms)? False when either is unknown."""
    if not isinstance(ts, str) or started_at is None:
        return False
    try:
        when = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return False
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    return when.timestamp() * 1000 >= started_at


def is_alias(model: object) -> bool:
    return isinstance(model, str) and not model.startswith("claude-") and ALIAS_RE.fullmatch(model) is not None


_PLAIN_ID = re.compile(r"claude-[a-z0-9.-]+(\[1m\])?", re.I)


def plain_model_id(model: str) -> str:
    """A model id as the table shows it: 'claude-sonnet-5-5' from a provider's spelling of it (the bedrock lane's
    ANTHROPIC_DEFAULT_SONNET_MODEL=global.anthropic.claude-sonnet-5-5, an ARN, Vertex's @date: spend.normalize_model, with a
    [1m] kept). An id already in the plain claude- form is returned as it is, date and all."""
    if _PLAIN_ID.fullmatch(model):
        return model
    out = normalize_model(model)
    return out + "[1m]" if out.startswith("claude-") and model.lower().endswith("[1m]") else out


def resolve_alias(alias: str, reply: dict, started_at: int | None, env: dict, catalog: dict) -> tuple[str | None, str | None]:
    """(exact id, how) for a bare alias, how being "reply", "env" or "catalog"; (None, None) when nothing names it.
    A [1m] on the alias carries over to the id."""
    m = ALIAS_RE.fullmatch(alias)
    name, wide = m.group(1).lower(), m.group(2) or ""

    def widen(model: str) -> str:
        return model if not wide or model.lower().endswith("[1m]") else model + wide

    default = (catalog.get("aliases") or {}).get(name) or (catalog.get("latest") or {}).get(name)
    default = plain_model_id(default) if isinstance(default, str) else default
    fam_m = re.match(r"claude-([a-z]+)-", default or "")
    fam = name if name in MODEL_FAMILIES else (fam_m.group(1) if fam_m else None)
    full = reply.get("model")
    if fam and isinstance(full, str) and full.startswith(f"claude-{fam}-") and _after_start(reply.get("ts"), started_at):
        return widen(full), "reply"
    override = env.get(name)
    if override and not is_alias(override):
        return widen(plain_model_id(override)), "env"
    if default:
        return widen(default), "catalog"
    return None, None


def model_family(model: object) -> str | None:
    """The family a model names: 'opus' for claude-opus-5-5[1m], a provider's spelling of it, or the bare alias opus[1m]; None
    when it names none (or nothing)."""
    if not isinstance(model, str) or not model:
        return None
    m = re.search(r"claude-([a-z]+)-", model, re.I) or ALIAS_RE.fullmatch(model)
    return m.group(1).lower() if m else None


def pane_config_dir(pid: int) -> str:
    """The CLAUDE_CONFIG_DIR in the process's environment: "" when it sets none or the environment is unreadable."""
    try:
        env = Path(f"/proc/{pid}/environ").read_bytes().split(b"\0")
    except OSError:
        return ""
    return next((e.split(b"=", 1)[1].decode(errors="replace") for e in env if e.startswith(b"CLAUDE_CONFIG_DIR=")), "")


def running_model(launch: dict, record: dict | None, reply: dict, started_at: int | None,
                  env: dict | None = None, catalog: dict | None = None, default: dict | None = None) -> dict:
    """{"model", "effort", "modelSource", "effortSource", "modelAlias"} of what a pane runs now (None where nothing says).
    The model: the launch line's, else sala's record, else the latest reply's ("launch", "record", "reply"); when none of
    the three names one (a session on the default model that sala's idle wrap-up just cleared), the CLI's default
    (`default["model"]`, spawn.claude_defaults: the default lane's settings.json), modelSource "default".
    A bare alias from any of them (opus) is resolved (resolve_alias: a newer reply of its family, the env override `env`,
    the binary's `catalog`): modelSource is then "alias", or stays "default" for the default's, and modelAlias says
    {"name": the alias, "from": "launch", "record" or "default", "via": "reply", "env", "catalog" or None, "binary": the
    CLI version whose catalog answered}. Unresolved, the model stays the alias with via None, which the page marks
    "version unknown". The effort: the launch line's, the record's, the reply's, else `default["effort"]`, effortSource
    naming which ("launch", "record", "reply", "default"); the default's effort is taken only when the model is the
    default one or of the default model's family (after an alias is resolved: `--model opus` resolved to claude-opus-5-5
    is of opus), since it is that family's setting: another family's pane keeps effort None. A default that is empty or
    missing is no default: the model and effort stay None, as before."""
    record = record or {}
    default = default or {}
    model = source = None
    for src, d in (("launch", launch), ("record", record), ("reply", reply), ("default", default)):
        if isinstance(d.get("model"), str) and d["model"]:
            model, source = d["model"], src
            break
    alias = None
    if is_alias(model):
        full, via = resolve_alias(model, reply, started_at, env or {}, catalog or {})
        alias = {"name": model, "from": source, "via": via,
                 "binary": (catalog or {}).get("binary") if via == "catalog" else None}
        model, source = full or model, "default" if source == "default" else "alias"
    effort = effort_source = None
    # the default's effort belongs to the default model's family (claude_defaults reads it from that family's settings): it
    # fills the gap only when the model is the default itself, or of the same family once an alias is resolved
    fam = model_family(model)
    default_fits = source == "default" or (fam is not None and fam == model_family(default.get("model")))
    for src, d in (("launch", launch), ("record", record), ("reply", reply), ("default", default)):
        if src == "default" and not default_fits:
            continue
        if isinstance(d.get("effort"), str) and d["effort"]:
            effort, effort_source = d["effort"], src
            break
    return {"model": model, "effort": effort, "modelSource": source, "effortSource": effort_source, "modelAlias": alias}


class RolesCache:
    """`client.py get roles`, cached for settings.roles_ttl seconds. A failure keeps the last good answer."""

    def __init__(self, settings: Settings):
        self.settings = settings
        self._roles: dict[str, dict] = {}
        self._fetched: float | None = None   # None: not asked yet (0.0 would look "just asked" within roles_ttl of the machine's boot)
        self._lock = asyncio.Lock()
        self.last_error: str | None = None

    async def get(self) -> dict[str, dict]:
        async with self._lock:
            if self._fetched is not None and time.monotonic() - self._fetched < self.settings.roles_ttl:
                return self._roles
            self._fetched = time.monotonic()
            if not self.settings.roles_cmd:   # SALA_STACKSHOT_DIR is empty: no stackshot on this box, nothing to ask
                self.last_error = "no roles command: SALA_STACKSHOT_DIR is empty (no stackshot on this box)"
                return self._roles
            try:
                proc = await asyncio.create_subprocess_exec(
                    *self.settings.roles_cmd,
                    stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
                stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=15)
                if proc.returncode != 0:
                    raise RuntimeError(f"roles command exited {proc.returncode}")
                sessions = json.loads(stdout).get("sessions") or {}
                if not isinstance(sessions, dict):
                    raise ValueError("roles: 'sessions' is not an object")
                self._roles = sessions
                self.last_error = None
            except Exception as e:  # tolerate failure: keep the last good roles
                self.last_error = f"{type(e).__name__}: {e}"
            return self._roles


# The fleet names sessions <scope>-<project>...; the scopes are this box's (scopes.py: SALA_SCOPES, else stackshot's list, else
# none); anything else is "other".
OTHER_SCOPE = "other"


def session_scope(name: str) -> str:
    prefix = name.split("-", 1)[0]
    return prefix if prefix in SC.names() else OTHER_SCOPE


def project_title(slug: str, scope: str) -> str:
    """'projects/demo-docs' under demo -> 'docs'; 'example/field-notes' -> 'field-notes'; 'projects/tracker' -> 'tracker'."""
    t = slug.split("/", 1)[1] if "/" in slug else slug
    if scope != OTHER_SCOPE and t.startswith(scope + "-") and len(t) > len(scope) + 1:
        t = t[len(scope) + 1:]
    return t


def _project_scope(members: list[Session]) -> str:
    """The scope most of the project's sessions carry; a tie goes to the first session in role order (front first)."""
    counts: dict[str, int] = {}
    for s in members:
        counts[session_scope(s.name)] = counts.get(session_scope(s.name), 0) + 1
    top = max(counts.values())
    for s in members:  # already sorted front, back, then by name
        if counts[session_scope(s.name)] == top:
            return session_scope(s.name)
    return OTHER_SCOPE


def load_agent_rows(path: Path) -> list[dict]:
    """The live rows of sala's session registry (`sessions.json`, docs/session-registry.md); [] when the file is missing or
    unreadable. Read-only."""
    try:
        with open(path, encoding="utf-8") as f:
            rows = (json.load(f) or {}).get("sessions") or {}
    except (OSError, ValueError, AttributeError):
        return []
    if not isinstance(rows, dict):
        return []
    return [r for r in rows.values() if isinstance(r, dict) and r.get("state") == "live" and isinstance(r.get("id"), str) and r["id"]]


def attach_agent_ids(sessions: list[Session], rows: list[dict]) -> None:
    """Give each session the permanent id of its registry row (and the names that row had), so a saved order survives what
    changes a name: a rename, a recycle that resumes a new conversation, a /clear. A live session finds its row by its
    Claude session id (the row's `transcripts`), else by its name, else by its tmux session (`pane`; the registry keeps one
    live row per name). A session with no row (a headless run, a side session before it is recorded) gets none, and the page
    keys it on its name. A row belongs to one session: a second session that would take the same row gets none."""
    by_sid: dict[str, dict] = {}
    by_name: dict[str, dict] = {}
    by_pane: dict[str, dict] = {}
    for r in rows:
        for t in r.get("transcripts") or []:
            if isinstance(t, dict) and isinstance(t.get("id"), str):
                by_sid.setdefault(t["id"], r)
        if isinstance(r.get("name"), str):
            by_name.setdefault(r["name"], r)
        if isinstance(r.get("pane"), str):
            by_pane.setdefault(r["pane"], r)
    taken: set[str] = set()

    def take(s: Session, row: dict | None) -> None:
        if row is None or row["id"] in taken or s.agent_id:
            return
        taken.add(row["id"])
        s.agent_id = row["id"]
        s.aliases = tuple(a for a in row.get("aliases") or [] if isinstance(a, str) and a)

    for s in sessions:   # the conversation first, for every session, so a name match never takes a row another session owns by it
        take(s, by_sid.get(s.session_id))
    for s in sessions:
        take(s, by_name.get(s.name) or by_pane.get(s.tmux_session))


def side_records(side_dir: Path | None) -> dict[str, dict]:
    """sala's side records (`<sala state>/side/<name>.side`, key=value lines written by `sala spawn --side`):
    session name -> the record's {"kind": fork | discuss, "origin", "project", "item"}. {} when the directory is missing or
    unreadable; a file that cannot be read is skipped. Read-only; the retired ones (side/retired/) are not here."""
    out: dict[str, dict] = {}
    if side_dir is None:
        return out
    try:
        files = list(side_dir.glob("*.side"))
    except OSError:
        return out
    for f in files:
        try:
            text = f.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        rec: dict[str, str] = {}
        for line in text.splitlines():
            k, sep, v = line.partition("=")
            if sep and k and k not in rec:
                rec[k] = v
        name = rec.get("name") or f.name[:-len(".side")]
        out[name] = {"kind": rec.get("kind", ""), "origin": rec.get("origin", ""), "project": rec.get("project", ""),
                     "item": rec.get("item", "")}
    return out


def side_project(name: str, records: dict[str, dict], roles: dict[str, dict]) -> str | None:
    """The project a side session is grouped under, from its record: a discuss session's is the project of its item; a
    fork's is the group its origin has now (the origin's own entry in `roles`, or, when the origin is itself a side session,
    the one its record gives, up the chain), else the project the record kept when the fork was made. None when there is no
    record, or it leads to no project (the session then stays in Unregistered)."""
    seen: set[str] = set()
    while name in records and name not in seen:
        seen.add(name)
        rec = records[name]
        if rec["kind"] == "discuss":
            return rec["project"] or None
        origin = rec["origin"]
        if origin:
            proj = (roles.get(origin) or {}).get("project")
            if proj:
                return proj
        if rec["project"]:
            return rec["project"]
        name = origin
    return None


def nearest_project(slug: str, types: dict[str, str]) -> str | None:
    """The page a session's group is: `slug` itself when its page is `type: project`, else its nearest parent by slug prefix
    that is (`projects/a/b/c` -> `projects/a/b` -> `projects/a`; the directory alone is no page). None when no page on the way
    is a project, or `types` (spawn.page_types: page key -> type) does not know it."""
    parts = slug.split("/")
    for n in range(len(parts), 1, -1):
        key = "/".join(parts[:n])
        if types.get(key) == "project":
            return key
    return None


def group_sessions(sessions: list[Session], roles: dict[str, dict], side: dict[str, dict] | None = None,
                   types: dict[str, str] | None = None) -> list[dict]:
    """Scopes (this box's, then other), each holding its project groups (by title), each holding its sessions
    (front agents first). Sessions with no project go to a last 'Unregistered' scope that holds one group of the
    same name, not split by scope. `side` is side_records(): a quick session is on no page's agents map, so when stackshot
    gives it no project its record does (side_project), and it is grouped there, with no role of its own.
    `types` is the pages' `type` field (spawn.page_types): a group exists only for a page whose type is `project`, and a
    session whose page is a sub-page or a note page is grouped under its nearest parent that is one (nearest_project); one
    with none stays in Unregistered. None (no pages checkout to read) leaves the project as stackshot's roles name it."""
    groups: dict[str, list[Session]] = {}
    side = side or {}
    for s in sessions:
        r = roles.get(s.name) or roles.get(s.session_id) or {}
        s.role = r.get("role")
        s.project = r.get("project")
        rec = side.get(s.name)
        if rec:
            s.side = {"kind": rec["kind"], "origin": rec["origin"], "item": rec["item"]}
            if not s.project:
                s.project = side_project(s.name, side, roles)
        if types is not None and s.project:
            s.project = nearest_project(s.project, types)
        groups.setdefault(s.project or UNREGISTERED, []).append(s)

    by_scope: dict[str, list[dict]] = {}
    for k, ms in groups.items():
        members = sorted(ms, key=lambda s: (ROLE_ORDER.get(s.role or "", 2), s.name.lower()))
        if k == UNREGISTERED:
            continue
        scope = _project_scope(members)
        by_scope.setdefault(scope, []).append(
            {"key": k, "title": project_title(k, scope), "scope": scope, "sessions": [s.to_json() for s in members]})
    result = []
    for scope in (*SC.names(), OTHER_SCOPE):
        if scope in by_scope:
            gs = sorted(by_scope[scope], key=lambda g: (g["title"].lower(), g["key"]))
            result.append({"key": scope, "title": scope, "groups": gs})
    if UNREGISTERED in groups:
        members = sorted(groups[UNREGISTERED], key=lambda s: s.name.lower())
        result.append({"key": UNREGISTERED, "title": UNREGISTERED, "flat": True, "groups": [
            {"key": UNREGISTERED, "title": UNREGISTERED, "scope": UNREGISTERED, "sessions": [s.to_json() for s in members]}]})
    return result


STATUS_LABEL = {"busy": "working", "shell": "shell", "waiting": "needs input"}


def overview_rows(sessions: list[Session], roles: dict[str, dict], side: dict[str, dict] | None = None,
                  types: dict[str, str] | None = None) -> list[dict]:
    """One row per session for the sessions table, in the sidebar's order (scope, project, front/back, name).
    The rows carry cwd, sessionId, tmuxSession and startedAt so the caller can find each transcript and sala's record
    and tell a reply newer than the process; it adds the model (running_model)."""
    rows = []
    for sc in group_sessions(sessions, roles, side, types):
        for g in sc["groups"]:
            for s in g["sessions"]:
                rows.append({
                    "name": s["name"], "pid": s["pid"], "sessionId": s["sessionId"], "cwd": s["cwd"],
                    "tmuxSession": s["tmuxSession"], "startedAt": s["startedAt"],
                    "scope": sc["key"], "project": s["project"],
                    "projectTitle": g["title"] if s["project"] else None,
                    "role": s["role"], "status": STATUS_LABEL.get(s["status"], s["status"]), "lane": s["lane"],
                    **({"parkedJob": s["parkedJob"]} if s.get("parkedJob") else {}),
                })
    return rows


def find_session(settings: Settings, pid: int) -> Session | None:
    for s in read_live_sessions(settings):
        if s.pid == pid:
            return s
    return None
