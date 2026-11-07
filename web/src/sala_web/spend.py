"""Month-to-date spend on the aws-platform (Claude Platform on AWS) and bedrock lanes, as an ESTIMATE AT LIST PRICES, counted
from this machine's own Claude Code transcripts.

Why our own count: the Platform org has no usage or cost API we can read (the Admin API's usage and cost endpoints are not
available to it) and AWS Cost Explorer lags a day and needs a permission nobody has granted, so the source is the transcripts:
every assistant reply carries message.usage (input, output, cache-read and the two cache-write tiers), which is multiplied by
the model's list price. The real bill (the AWS Console shows list price with about two hours' lag; the AWS Marketplace
invoice may differ) can differ from this figure, and the card says so. Nothing here asks AWS or Anthropic anything and no
AWS credential is read: sala's lane table is asked only whether the lane is set up.

THE METHOD (the same rates and the same dedupe as a separate fleet spend report script, if the operator keeps one):
- a streamed reply is several transcript lines with one message id whose output_tokens grows block by block, and a session
  moved to another lane or forked copies its history: each message id is counted once, taking the largest value of every
  token field (the complete usage), across every file; a hand count that took the first line read output tokens short;
- subagent transcripts (<session>/subagents/**/*.jsonl) belong to the session whose directory holds them and are counted;
- 5-minute and 1-hour cache writes are priced apart (usage.cache_creation.ephemeral_{5m,1h}_input_tokens; an older row with
  only cache_creation_input_tokens is taken as 5-minute); cache reads at the cache-read rate;
- a model with no rate is listed as unpriced, never counted as $0 silently;
- the month is the UTC calendar month (the Console resets on the 1st, UTC); a message counts when its timestamp is in it.

WHICH LANE A MESSAGE WAS ON. The two AWS lanes run with the default config directory (no CLAUDE_CONFIG_DIR), so a transcript's
folder says nothing about the lane: the lane is read from sala's records, per session and per message time.
  1. lanes.log (sala's change record, `ISO TAB op TAB session TAB old → new TAB who`) gives the lane a session was put on and
     when (`set`, `drop`; `default` moves the default lane that "(default)" means). The lane at time t is the `new` of the
     latest change at or before t, and before the first change the `old` of that first change.
  2. what this page itself sees of the live claude processes (sessions.proc_lane, from the process environment, the truth for a
     process) is remembered in the state dir with the time the process started: from that time on the session is on the lane
     the process runs on. It outranks a change record older than it.
  3. a session with no record of either kind is on its CURRENT lane for all its messages: the live process's, else the
     registry's row (sessions.json), else lanes.tsv, else the default.
KNOWN INACCURACIES. (a) A change in lanes.log is when the lane was RECORDED; the session moves at its next relaunch, so the
messages between the two (usually minutes) are put on the new lane. (b) A session launched by hand on an AWS lane that sala
never recorded has only rule 3 for the time before this page first saw it: all its earlier messages count on the current
lane. (c) A session named in lanes.log whose transcript cannot be matched (no registry row, no live process) is not counted
and the card says how many. (d) Only transcripts under the default config directory (claude_dir/projects) are read.

KEEPING IT CHEAP. Only the sessions that are or were on an AWS lane are read (the others cannot hold a message of these lanes),
files untouched since the month began are skipped, and every file is read from where the last read stopped: the cache in
the state dir (spend-scan.json) holds, per file, its inode, the offset after its last complete line and the month's
messages as (id, time, model, five token counts). Nothing else leaves a transcript: no prompt, no reply text, no tool input.
The first read of a big session can take a while: the answer is "pending" until it lands (swr.py), and it runs in a thread.
"""

from __future__ import annotations

import asyncio
import json
import os
import re
from bisect import bisect_right
from datetime import datetime, timezone
from pathlib import Path
from typing import Awaitable, Callable

from . import lanestate as LS
from . import swr as SWR

LANES = ("aws-platform", "bedrock")
TTL = 300.0           # one count per 5 minutes, however many pages ask
ERROR_RETRY = 60.0    # a count that failed is tried again a minute later
SCAN_VERSION = 1
MAX_RECORDS = 250_000  # messages kept in memory and in the cache file; more is an error on the card, not a slow crash
KEEP_OBSERVED = 20     # lane sightings kept per session

# $ per MTok: input, cache write 5m, cache write 1h, cache read, output: the models' list prices. A separate fleet
# spend report script, if the operator keeps one, carries the same table; keep the two in step.
PRICES = {
    "claude-opus-5-5": (4, 5, 8, 0.20, 20),
    "claude-fable-5-1": (10, 12.5, 20, 0.25, 50),
    "claude-sonnet-5-5": (2, 2.5, 4, 0.10, 10),
    "claude-opus-5": (5, 6.25, 10, 0.50, 25),
    "claude-haiku-5-5": (0.1, 0.125, 0.2, 0.01, 0.5),
    "claude-haiku-4-5": (1, 1.25, 2, 0.10, 5),
}

_REGION = re.compile(r"^(?:global|us|eu|apac|jp|au|us-gov)\.")
_PROVIDER = re.compile(r"^anthropic\.")
_BEDROCK_VERSION = re.compile(r"(?:-v\d+(?::\d+)?|:\d+)$")   # "-v1:0", "-v2", a bare ":0"
_VERTEX_AT = re.compile(r"@[^@/]*$")                           # Vertex's "@20250929" and "@default"
_DATE = re.compile(r"-\d{8}$")
_WIDE = re.compile(r"\[1m\]$")


class SpendError(Exception):
    """A plain sentence for the card (never carries a path's content, a prompt or a secret)."""


def normalize_model(raw: object) -> str:
    """'global.anthropic.claude-opus-5-5-20260101-v1:0' -> 'claude-opus-5-5': a [1m] marker, an ARN's path ("arn:…:inference-profile/"),
    Vertex's @date or @default, the region prefix, the provider prefix, Bedrock's version suffix and a date taken off, in that
    order; anything else is returned as it is (lower case). It also takes the ARN, @ and bare ":0" forms and the sessions
    table's use of this for a model named only by a provider's id."""
    m = str(raw or "").strip().lower()
    m = _WIDE.sub("", m)
    m = m.rsplit("/", 1)[-1]
    m = _VERTEX_AT.sub("", m)
    m = _REGION.sub("", m)
    m = _PROVIDER.sub("", m)
    m = _BEDROCK_VERSION.sub("", m)
    m = _DATE.sub("", m)
    return m


def price(model: str, tok: list[int | float]) -> float | None:
    """The list price in USD of [input, cache write 5m, cache write 1h, cache read, output] tokens on a model; None when the
    model has no rate."""
    p = PRICES.get(normalize_model(model))
    if p is None:
        return None
    return sum(t * r for t, r in zip(tok, p)) / 1e6


def month_start(now: datetime) -> datetime:
    n = now.astimezone(timezone.utc)
    return datetime(n.year, n.month, 1, tzinfo=timezone.utc)


def parse_iso(s: object) -> float | None:
    """An ISO time as epoch seconds; None when it is not one."""
    if not isinstance(s, str):
        return None
    try:
        d = datetime.fromisoformat(s.strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    if d.tzinfo is None:
        d = d.replace(tzinfo=timezone.utc)
    return d.timestamp()


# ── what sala knows about lanes ──────────────────────────────────────────────
DEFAULT = "(default)"


def read_lane_log(path: Path) -> tuple[dict[str, list], list]:
    """({session name: [(epoch s, old, new, line no.)]}, [the same for the default lane]) from lanes.log, in file order.
    A missing file is no record; an unreadable one is a SpendError. Lines of any other op (dormant, active, rescue,
    fallback) and odd lines are skipped: a `rescue` also writes a `set`."""
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except FileNotFoundError:
        return {}, []
    except OSError:
        raise SpendError("sala's lane record could not be read") from None
    events: dict[str, list] = {}
    defaults: list = []
    for seq, line in enumerate(text.splitlines()):
        cols = line.split("\t")
        if len(cols) < 4 or cols[1] not in ("set", "drop", "default"):
            continue
        t = parse_iso(cols[0])
        old, arrow, new = cols[3].partition(" → ")
        if t is None or not arrow:
            continue
        old, new = old.strip(), new.strip()
        if cols[1] == "default":
            defaults.append((t, old, new, seq))
        else:
            events.setdefault(cols[2], []).append((t, old, new, seq))
    return events, defaults


def read_json(path: Path, what: str) -> dict:
    """A JSON object from a file of sala's; {} when the file is missing; a SpendError when it is there and unreadable."""
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    except (OSError, ValueError):
        raise SpendError(f"{what} could not be read") from None
    return doc if isinstance(doc, dict) else {}


def read_tsv(path: Path) -> dict[str, str]:
    """lanes.tsv: {session name: lane}; missing is empty."""
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except FileNotFoundError:
        return {}
    except OSError:
        raise SpendError("sala's lane record could not be read") from None
    out = {}
    for line in text.splitlines():
        cols = line.split("\t")
        if len(cols) >= 2 and cols[0]:
            out[cols[0]] = cols[1].strip()
    return out


def canonical(lane: str) -> str:
    """sdk is api's word; awsplatform, max and team are the old names of aws-platform, subscription-1 and subscription-2
    (lanestate.RENAMED): lanes.log, lanes.tsv, the registry and the sightings in spend-lanes.json written before a rename still
    say them, and are counted as the new name."""
    return LS.norm(lane)


class Facts:
    """Everything the lane of a message is worked out from, read once per count."""

    def __init__(self, sala_dir: Path, live: list, observed: dict):
        self.events, self.default_events = read_lane_log(sala_dir / "lanes.log")
        self.rows = read_tsv(sala_dir / "lanes.tsv")
        try:
            self.default_now = (sala_dir / "lane-default").read_text(encoding="utf-8").strip() or "subscription-1"
        except OSError:
            self.default_now = "subscription-1"
        self.default_events.sort(key=lambda e: (e[0], e[3]))
        reg = read_json(sala_dir / "sessions.json", "sala's session record").get("sessions")
        self.names: dict[str, set[str]] = {}     # transcript id -> the names its session has had
        self.shown: dict[str, str] = {}          # transcript id -> the name to show
        self.reg_lane: dict[str, str] = {}       # transcript id -> the registry row's lane
        self.live = {s.session_id: s for s in live if getattr(s, "session_id", "")}
        for row in (reg.values() if isinstance(reg, dict) else []):
            if not isinstance(row, dict) or not isinstance(row.get("name"), str):
                continue
            names = {row["name"], *[a for a in row.get("aliases") or [] if isinstance(a, str)]}
            ids = {t.get("id") for t in row.get("transcripts") or [] if isinstance(t, dict)} | {row.get("id")}
            for i in ids:
                if isinstance(i, str) and i:
                    self.names.setdefault(i, set()).update(names)
                    self.shown[i] = row["name"]
                    if isinstance(row.get("lane"), str):
                        self.reg_lane[i] = canonical(row["lane"])
        for sid, s in self.live.items():
            self.names.setdefault(sid, set()).add(s.name)
            self.shown.setdefault(sid, s.name)
        self.observed = observed
        for sid, o in observed.items():
            if isinstance(o.get("name"), str) and o["name"]:
                self.names.setdefault(sid, set()).add(o["name"])
                self.shown.setdefault(sid, o["name"])

    def default_at(self, t: float) -> str:
        """The default lane at epoch second t: what the latest `default` change at or before t made it, before the first
        change the first change's old lane, with no change the default now."""
        if not self.default_events:
            return canonical(self.default_now)
        i = bisect_right([e[0] for e in self.default_events], t)
        return canonical(self.default_events[i - 1][2] if i else self.default_events[0][1])

    def lane_word(self, word: str, t: float) -> str:
        return self.default_at(t) if word == DEFAULT else canonical(word)

    def current(self, sid: str) -> str:
        """The lane the session is on NOW: the live process's, else the registry row's, else lanes.tsv, else the default."""
        s = self.live.get(sid)
        if s is not None and getattr(s, "lane", None):
            return canonical(s.lane)
        if sid in self.reg_lane:
            return self.reg_lane[sid]
        for n in sorted(self.names.get(sid, ())):
            if n in self.rows:
                return canonical(self.rows[n])
        return canonical(self.default_now)

    def points(self, sid: str) -> list[tuple[float, str]]:
        """[(epoch s, lane)] sorted by time: each lanes.log change of the session's names (the lane it set, "(default)"
        read as the default then) and each sighting of a live process (its start time, the lane it ran on)."""
        pts: list[tuple[float, int, str]] = []
        for name in self.names.get(sid, ()):
            for t, _old, new, seq in self.events.get(name, ()):   # the file's order breaks a tie: a rename is a drop then a set in one second
                pts.append((t, seq, self.lane_word(new, t)))
        for n, (since, lane) in enumerate((self.observed.get(sid) or {}).get("seen", [])):
            pts.append((since / 1000.0, 10**9 + n, canonical(lane)))
        pts.sort(key=lambda p: (p[0], p[1]))
        return [(t, lane) for t, _, lane in pts]

    def before(self, sid: str) -> str:
        """The lane before the session's first recorded change: that change's old lane, else the current lane."""
        first = None
        for name in self.names.get(sid, ()):
            for e in self.events.get(name, ()):
                if first is None or (e[0], e[3]) < (first[0], first[3]):
                    first = e
        return self.lane_word(first[1], first[0]) if first else self.current(sid)

    def timeline(self, sid: str) -> "Timeline":
        return Timeline(self.points(sid), self.before(sid), self.current(sid))

    def aws_lanes_of(self, sid: str) -> set[str]:
        """Every AWS lane the session is or was on, by any record: the reason to read its transcripts at all."""
        out = {self.current(sid)} | {lane for _, lane in self.points(sid)} | {self.before(sid)}
        return {lane for lane in out if lane in LANES}


class Timeline:
    def __init__(self, points: list[tuple[float, str]], before: str, current: str):
        self.times = [p[0] for p in points]
        self.lanes = [p[1] for p in points]
        self._before = before if points else current   # no record of a change: the current lane, for every message

    def lane_at(self, t: float) -> str:
        i = bisect_right(self.times, t)
        return self.lanes[i - 1] if i else self._before


# ── reading a transcript ─────────────────────────────────────────────────────
def usage_tokens(u: dict) -> list[int]:
    """[input, cache write 5m, cache write 1h, cache read, output]."""
    cc = u.get("cache_creation") if isinstance(u.get("cache_creation"), dict) else {}
    w5, w1 = cc.get("ephemeral_5m_input_tokens"), cc.get("ephemeral_1h_input_tokens")
    if w5 is None and w1 is None:
        w5, w1 = u.get("cache_creation_input_tokens") or 0, 0
    out = []
    for v in (u.get("input_tokens"), w5, w1, u.get("cache_read_input_tokens"), u.get("output_tokens")):
        out.append(int(v) if isinstance(v, (int, float)) and v > 0 else 0)
    return out


def read_new(path: Path, entry: dict, since_ms: float) -> int:
    """Read what was appended to a transcript since entry["off"], adding the month's messages to entry["recs"] ({message id:
    [epoch ms, model, five token counts…]}; a message seen again keeps the larger of each count). Only whole lines are read:
    the offset stops at the last newline, so a line still being written is read next time. Returns the bytes read."""
    with open(path, "rb") as fh:
        fh.seek(entry["off"])
        pos = entry["off"]
        recs = entry["recs"]
        for raw in fh:
            if not raw.endswith(b"\n"):
                break
            pos += len(raw)
            if b'"usage"' not in raw or b'"assistant"' not in raw:
                continue
            try:
                d = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(d, dict) or d.get("type") != "assistant":
                continue
            m = d.get("message")
            if not isinstance(m, dict) or not isinstance(m.get("usage"), dict):
                continue
            model = m.get("model")
            mid = m.get("id") or d.get("requestId")
            t = parse_iso(d.get("timestamp"))
            if not mid or not isinstance(model, str) or model == "<synthetic>" or t is None or t * 1000 < since_ms:
                continue
            tok = usage_tokens(m["usage"])
            old = recs.get(mid)
            if old is not None:   # a streamed block of the same message: the largest value of each count is the whole reply's
                tok = [max(a, b) for a, b in zip(old[2:], tok)]
            recs[mid] = [int(t * 1000), model, *tok]
        n = pos - entry["off"]
        entry["off"] = pos
        return n


class ScanCache:
    """Per file: inode, offset and the month's messages; saved as JSON in the state dir."""

    def __init__(self, path: Path | None, month: str):
        self.path = path
        self.month = month
        self.files: dict[str, dict] = {}
        self.dirty = False
        if path is None:
            return
        try:
            doc = json.loads(path.read_text())
        except (OSError, ValueError):
            return
        if isinstance(doc, dict) and doc.get("v") == SCAN_VERSION and doc.get("month") == month and isinstance(doc.get("files"), dict):
            self.files = {k: v for k, v in doc["files"].items() if isinstance(v, dict) and isinstance(v.get("recs"), dict)}

    def scan(self, path: Path, since_ms: float) -> int:
        """Bring one file's entry up to its end; the bytes read. A file that shrank or was replaced is read again from 0."""
        key = str(path)
        st = path.stat()
        e = self.files.get(key)
        if e is None or e.get("ino") != st.st_ino or e.get("off", 0) > st.st_size:
            e = self.files[key] = {"ino": st.st_ino, "off": 0, "recs": {}}
        if e["off"] >= st.st_size:
            return 0
        n = read_new(path, e, since_ms)
        self.dirty = True
        return n

    def records(self) -> int:
        return sum(len(e["recs"]) for e in self.files.values())

    def save(self) -> None:
        if self.path is None or not self.dirty:
            return
        try:
            SWR.write_atomic(self.path, {"v": SCAN_VERSION, "month": self.month, "files": self.files})
        except OSError:
            return
        self.dirty = False


def transcript_files(projects: Path, sid: str, since: float) -> list[Path]:
    """Every transcript of a session under the projects directory, subagents included, modified since the month began."""
    out: list[Path] = []
    try:
        folders = [p for p in projects.iterdir() if p.is_dir()]
    except OSError:
        raise SpendError("the transcripts folder could not be read") from None
    for folder in folders:
        main = folder / f"{sid}.jsonl"
        if main.is_file():
            out.append(main)
        sub = folder / sid / "subagents"
        if sub.is_dir():
            out.extend(sub.rglob("*.jsonl"))
    keep = []
    for p in out:
        try:
            if p.stat().st_mtime >= since:
                keep.append(p)
        except OSError:
            continue
    return sorted(keep)


def sid_of(projects: Path, path: str) -> str:
    """The session a transcript file belongs to: its own name, or for a subagent's the directory above 'subagents'."""
    rel = Path(path).relative_to(projects).parts
    return rel[1] if len(rel) > 2 and rel[2] == "subagents" else Path(rel[-1]).stem


# ── the count ────────────────────────────────────────────────────────────────
def load_observed(path: Path | None) -> dict:
    if path is None:
        return {}
    try:
        doc = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    sess = doc.get("sessions") if isinstance(doc, dict) else None
    out = {}
    for sid, o in (sess.items() if isinstance(sess, dict) else []):
        if isinstance(sid, str) and isinstance(o, dict) and isinstance(o.get("seen"), list):
            seen = [[s[0], s[1]] for s in o["seen"] if isinstance(s, list) and len(s) == 2
                    and isinstance(s[0], (int, float)) and isinstance(s[1], str)]
            out[sid] = {"name": o.get("name") if isinstance(o.get("name"), str) else "", "seen": seen}
    return out


def note_live(observed: dict, live: list, now_ms: int) -> bool:
    """Remember which lane each live process runs on, from the time it started. Only sessions that are on an AWS lane now or
    were seen before are kept (the rest cannot hold a message of these lanes). True when something was added."""
    changed = False
    for s in live:
        sid, lane = getattr(s, "session_id", ""), getattr(s, "lane", None)
        if not sid or not lane:
            continue
        lane = canonical(lane)
        if lane not in LANES and sid not in observed:
            continue
        since = getattr(s, "started_at", None)
        o = observed.setdefault(sid, {"name": s.name, "seen": []})
        if o["name"] != s.name:
            o["name"], changed = s.name, True
        if since is None:   # the registry did not say when the process started: first sight is now; a sighting on the same lane later adds nothing
            if o["seen"] and o["seen"][-1][1] == lane:
                continue
            since = now_ms
        if not any(abs(x[0] - since) < 1000 and x[1] == lane for x in o["seen"]):
            o["seen"] = sorted([*o["seen"], [since, lane]])[-KEEP_OBSERVED:]
            changed = True
    return changed


def compute(settings, live: list, configured: dict[str, bool | None], now: datetime, scan_path: Path | None,
            observed_path: Path | None) -> dict:
    """The answer for both lanes (blocking: run it in a thread). Raises SpendError."""
    start = month_start(now)
    month = start.strftime("%Y-%m")
    since_ms = start.timestamp() * 1000
    observed = load_observed(observed_path)
    if note_live(observed, live, int(now.timestamp() * 1000)) and observed_path is not None:
        try:
            SWR.write_atomic(observed_path, {"v": 1, "sessions": observed})
        except OSError:
            pass
    facts = Facts(settings.sala_state_dir, live, observed)
    projects = settings.projects_dir

    # the sessions to read: the ones any record puts on an AWS lane, now or at some time
    sids = sorted(i for i in facts.names if facts.aws_lanes_of(i))
    cache = ScanCache(scan_path, month)
    lanes_of_sid = {i: facts.timeline(i) for i in sids}
    scanned = 0
    found: set[str] = set()
    wanted: set[str] = set()
    for sid in sids:
        for p in transcript_files(projects, sid, start.timestamp()):
            try:
                scanned += cache.scan(p, since_ms)
            except OSError:
                continue
            found.add(sid)
            wanted.add(str(p))
        if cache.records() > MAX_RECORDS:
            raise SpendError("there are too many messages to count")
    for k in [k for k in cache.files if k not in wanted]:   # a file no AWS session owns (any more) is not kept
        del cache.files[k]
        cache.dirty = True
    cache.save()

    # one message once, whichever file holds it: the largest of each count (a fork copies history), the first file by path
    # keeps it; then the lane at the message's time and the price
    merged: dict[str, tuple[str, list]] = {}
    for path in sorted(cache.files):
        sid = sid_of(projects, path) if path.startswith(str(projects) + os.sep) else None
        if sid not in lanes_of_sid:
            continue
        for mid, r in cache.files[path]["recs"].items():
            old = merged.get(mid)
            if old is None:
                merged[mid] = (sid, list(r))
            else:
                old[1][2:] = [max(a, b) for a, b in zip(old[1][2:], r[2:])]

    acc = {lane: {"usd": 0.0, "calls": 0, "models": {}, "sessions": {}, "unpriced": {}} for lane in LANES}
    for sid, r in merged.values():
        lane = lanes_of_sid[sid].lane_at(r[0] / 1000.0)
        if lane not in acc:
            continue
        a = acc[lane]
        model = normalize_model(r[1])
        usd = price(model, r[2:])
        a["calls"] += 1
        s = a["sessions"].setdefault(sid, {"usd": 0.0, "calls": 0})
        s["calls"] += 1
        if usd is None:
            u = a["unpriced"].setdefault(model, {"calls": 0, "tokens": 0})
            u["calls"] += 1
            u["tokens"] += sum(r[2:])
            continue
        a["usd"] += usd
        s["usd"] += usd
        m = a["models"].setdefault(model, {"usd": 0.0, "calls": 0})
        m["usd"] += usd
        m["calls"] += 1

    # sessions named in lanes.log on an AWS lane whose transcript could not be matched (no registry row and not live)
    named_ids = {n for ns in facts.names.values() for n in ns}
    unmatched: dict[str, set[str]] = {lane: set() for lane in LANES}
    for name, ev in facts.events.items():
        if name in named_ids:
            continue
        for t, old, new, _seq in ev:
            for w in (old, new):
                lane = facts.lane_word(w, t)
                if lane in unmatched:
                    unmatched[lane].add(name)

    out = []
    for lane in LANES:
        a = acc[lane]
        total = a["usd"]
        sessions = []
        for sid, s in a["sessions"].items():
            sessions.append({"sessionId": sid, "name": facts.shown.get(sid) or sid[:8], "usd": round(s["usd"], 4),
                             "calls": s["calls"], "share": round(s["usd"] / total, 4) if total > 0 else None,
                             "live": sid in facts.live})
        sessions.sort(key=lambda x: (-x["usd"], x["name"]))
        out.append({
            "lane": lane,
            "configured": configured.get(lane),
            "monthUsd": round(total, 4),
            "calls": a["calls"],
            "models": sorted(({"model": m, "usd": round(v["usd"], 4), "calls": v["calls"]} for m, v in a["models"].items()),
                             key=lambda x: (-x["usd"], x["model"])),
            "sessions": sessions,
            "unpriced": sorted(({"model": m, "calls": v["calls"], "tokens": v["tokens"]} for m, v in a["unpriced"].items()),
                               key=lambda x: (-x["calls"], x["model"])),
            "unmatched": sorted(unmatched[lane]),
        })
    return {"month": month, "since": start.strftime("%Y-%m-%dT%H:%M:%SZ"), "lanes": out,
            "scannedBytes": scanned, "sessionsRead": len(found)}


class SpendCache:
    """The two lanes' month-to-date spend, served at once from the last good answer (memory, and a file in the state dir so a
    restart has it) and refreshed in the background once it is TTL old. The count runs in a thread; with no answer yet the
    card is 'pending'. A failure keeps the last answer and adds `error` in plain words. The file holds figures, session names
    and times, never a secret (there is none here) or the error text."""

    def __init__(self, settings, live: Callable[[], list], lane_status: Callable[[], Awaitable[dict]] | None = None):
        sd = settings.state_dir
        self.settings = settings
        self.live = live
        self.lane_status = lane_status
        self.scan_path = sd / "spend-scan.json"
        self.observed_path = sd / "spend-lanes.json"
        self._swr = SWR.Revalidating(sd / "spend-aws.json", TTL, ERROR_RETRY, {"lanes": []},
                                     valid=lambda d: isinstance(d.get("lanes"), list) and isinstance(d.get("month"), str))

    def get(self) -> dict:
        return self._swr.serve(self._refresh)

    async def _refresh(self) -> dict:
        try:
            configured: dict = {}
            if self.lane_status is not None:
                try:
                    configured = await self.lane_status() or {}
                except Exception:   # sala not answering is "not known", never a failed count
                    configured = {}
            live = await asyncio.to_thread(self.live)
            return await asyncio.to_thread(compute, self.settings, live, configured, datetime.now(timezone.utc),
                                           self.scan_path, self.observed_path)
        except SpendError as e:
            raise SWR.Failed(str(e)) from None
        except Exception as e:  # never str(e): an unexpected error could carry anything
            raise SWR.Failed(f"the spend could not be counted ({type(e).__name__})") from None
