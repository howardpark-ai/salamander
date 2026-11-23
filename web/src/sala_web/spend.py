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
  token field (the complete usage) across the lines of a message, and across files the first file read keeps a copied message; a
  hand count that took the first line read output tokens short;
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
files untouched since the month began are skipped, and every file is read from where the last read stopped. The count keeps NO list of
messages: the cache in the state dir (spend-scan.sqlite3, a SQLite file) holds, per transcript, its inode, the offset after its last
complete line and its TOTALS so far (per lane and model: how many messages and the five token counts), and for the whole month the set of
the ids of the messages already counted. A read takes the lines a transcript gained, closes each message into that transcript's totals
(on the lane its session was on at the message's time; an id already in the set is a fork's copy of a message counted before, and is not
counted again) and writes totals, set and offset in one transaction. The card is the sum of the totals, priced at the end. So a count's
memory is a few hundred messages (the ones of the transcript being read), whatever the month holds, and nothing limits how many messages
there are. Across transcripts the first one to count a message keeps it (a copy of a finished reply carries the same counts, so which one does not change
the figures; it decides which session the message is listed under). The newest few messages of a transcript stay open
(TAIL_KEEP) and are counted from there until a later read closes them, so the rest of a streamed reply that arrives after a count is merged
into the message it belongs to (the largest of each count), not counted twice. A transcript that was replaced, shrank or is no longer one of
the AWS sessions' (rare: transcripts only grow) cannot be taken out of totals the copies' dedupe rests on: the month is then read again
from the first byte. The one thing that can grow without end is the set of ids, on disk (about 60 bytes a message); the file is held under
MAX_STORE_BYTES, which is a disk limit about a hundred months' messages away, not a count of messages. The cache an earlier release kept
as JSON (spend-scan.json) is read once into the new file and removed; one that cannot be read is dropped and the month is read again.
The first read of a big session can take a while: the answer is "pending" until it lands (swr.py), and it runs in a thread.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import os
import re
import sqlite3
from bisect import bisect_right
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Awaitable, Callable

from . import lanestate as LS
from . import swr as SWR

LANES = ("aws-platform", "bedrock")
TTL = 300.0           # one count per 5 minutes, however many pages ask
ERROR_RETRY = 60.0    # a count that failed is tried again a minute later
SCAN_VERSION = 2      # the SQLite cache's layout; the JSON cache of version 1 is only ever read to be converted
SCAN_FILE = "spend-scan.sqlite3"
LEGACY_SCAN_FILE = "spend-scan.json"   # the cache before SCAN_VERSION 2: converted once, then removed
LEGACY_MAX_BYTES = 64_000_000          # an old cache past this (it held 27 MB at its own cap) is not read whole: the month is read again
MAX_STORE_BYTES = 2 << 30   # what the cache file may grow to: a disk limit (the id set is most of it, about 60 bytes a message), not a count of messages
PENDING_MAX = 64            # messages of one transcript held at once while it is read; the oldest is closed into the totals
TAIL_KEEP = 4               # the newest messages of a transcript stay open between two reads (see KEEPING IT CHEAP)
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
# The marker the Usage analysis tab prints beside the prices ("as of"). It says when the table was last read against the published price
# page: whoever checks the prices, or changes a row above, sets it in the same commit. It is not a verification date by itself.
PRICES_AS_OF = "2026-11-07"

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


_TOKEN_MAX = 1 << 60   # a count past this is not a count (and would not fit SQLite's integer): clamped
_TCOLS = ("t0", "t1", "t2", "t3", "t4")


def read_new(path: Path, off: int, since_ms: float, pending: dict, fold: Callable[[str, list], None]) -> int:
    """Read what was appended to a transcript since `off`. A message is a record [epoch ms, model, five token counts] in `pending` ({message id:
    record}, in the order its ids were first seen; the caller seeds it with the messages the last read left open): a line of a message already in
    it keeps the larger of each count (a streamed reply's complete usage) and the last line's time and model. When more than PENDING_MAX
    messages are held, the oldest is closed: `fold(id, record)`. What is left in `pending` stays for the caller to close or keep open. Only
    whole lines are read: the offset stops at the last newline, so a line still being written is read next time. The memory is PENDING_MAX
    records, whatever the size of the transcript. Returns the offset after the last whole line."""
    pos = off
    with open(path, "rb") as fh:
        fh.seek(off)
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
            if not isinstance(mid, str) or not isinstance(model, str) or model == "<synthetic>" or t is None or t * 1000 < since_ms:
                continue
            try:
                tok = [min(v, _TOKEN_MAX) for v in usage_tokens(m["usage"])]
            except OverflowError:   # a count of "Infinity"
                continue
            old = pending.get(mid)
            if old is not None:   # a streamed block of the same message: the largest value of each count is the whole reply's
                tok = [max(a, b) for a, b in zip(old[2:], tok)]
            pending[mid] = [int(t * 1000), model, *tok]   # an id seen again keeps its place
            while len(pending) > PENDING_MAX:
                k = next(iter(pending))
                fold(k, pending.pop(k))
    return pos


_SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS files (fid INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, ino INTEGER NOT NULL, off INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS ids (mid TEXT PRIMARY KEY) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS tally (fid INTEGER NOT NULL, lane TEXT NOT NULL, model TEXT NOT NULL, calls INTEGER NOT NULL,
    t0 INTEGER NOT NULL, t1 INTEGER NOT NULL, t2 INTEGER NOT NULL, t3 INTEGER NOT NULL, t4 INTEGER NOT NULL,
    PRIMARY KEY (fid, lane, model)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS tails (fid INTEGER NOT NULL, mid TEXT NOT NULL, ms INTEGER NOT NULL, model TEXT NOT NULL,
    t0 INTEGER NOT NULL, t1 INTEGER NOT NULL, t2 INTEGER NOT NULL, t3 INTEGER NOT NULL, t4 INTEGER NOT NULL,
    PRIMARY KEY (fid, mid)) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS tails_mid ON tails (mid);
"""
_TALLY_UPSERT = ("INSERT INTO tally(fid, lane, model, calls, t0, t1, t2, t3, t4) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) "
                 "ON CONFLICT(fid, lane, model) DO UPDATE SET calls = calls + excluded.calls, "
                 + ", ".join(f"{c} = {c} + excluded.{c}" for c in _TCOLS))


class _Folder:
    """Closes messages of one transcript into its totals: a message whose id no transcript has closed before, and none holds open, is counted, on the lane
    its session was on at the message's time (an id seen before is a copy of it, a fork's history, and is not counted again); `flush` writes the totals."""

    def __init__(self, db: sqlite3.Connection, fid: int, timeline: "Timeline"):
        self.db, self.fid, self.timeline = db, fid, timeline
        self.sums: dict[tuple[str, str], list[int]] = {}

    def __call__(self, mid: str, rec: list) -> None:
        if self.db.execute("SELECT 1 FROM tails WHERE mid = ? AND fid != ?", (mid, self.fid)).fetchone():
            return   # another transcript still holds this message open (a fork's copy of the parent's newest replies): it keeps it
        if self.db.execute("INSERT OR IGNORE INTO ids VALUES (?)", (mid,)).rowcount != 1:
            return
        lane = self.timeline.lane_at(rec[0] / 1000.0)
        if lane not in LANES:
            return
        s = self.sums.setdefault((lane, normalize_model(rec[1])), [0] * 6)
        s[0] += 1
        for i in range(5):
            s[i + 1] += rec[2 + i]

    def flush(self) -> None:
        if self.sums:
            self.db.executemany(_TALLY_UPSERT, [(self.fid, lane, model, *s) for (lane, model), s in self.sums.items()])
            self.sums.clear()

    def keep_open(self, pending: dict) -> None:
        """Close all but the newest TAIL_KEEP messages and store those as the transcript's open messages: the next read of the file may carry
        the rest of a streamed reply, which is then merged into them instead of counted a second time."""
        while len(pending) > TAIL_KEEP:
            k = next(iter(pending))
            self(k, pending.pop(k))
        self.flush()
        self.db.execute("DELETE FROM tails WHERE fid = ?", (self.fid,))
        self.db.executemany("INSERT INTO tails VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", [(self.fid, k, *v) for k, v in pending.items()])


class ScanStore:
    """The month's read cache: a SQLite file in the state dir (None: in memory), used by one count from one thread. It holds NO message list.
    Per transcript: its inode, the offset after its last complete line, the totals of the messages closed so far (per lane and model: how many
    and the five token counts) and the few messages still open (TAIL_KEEP, newest). For the whole month: the set of the ids of the messages
    closed, which is what keeps a fork's copied history from being counted twice. A transcript's new lines, its offset, its totals and its
    open messages are written in one transaction, so a count stopped half way leaves the file as it was before that transcript."""

    def __init__(self, path: Path | None, month: str):
        self.path = path
        self.month = month
        if path is not None:
            path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            os.close(os.open(path, os.O_RDWR | os.O_CREAT, 0o600))   # owner-only, as the rest of the state dir
        self.db = sqlite3.connect(str(path) if path is not None else ":memory:", timeout=30, isolation_level=None)
        try:
            self.db.executescript("PRAGMA temp_store = FILE; PRAGMA cache_size = -8192; PRAGMA synchronous = NORMAL;" + _SCHEMA)
            self.fresh = self._meta("v") is None   # nothing in it yet: the place to read an older release's cache into
            if not self.fresh and (self._meta("v") != SCAN_VERSION or self._meta("month") != self.month):
                self.reset()   # a new month, or a layout this code does not know
                self.fresh = True
            if self._meta("v") is None:
                with self.tx():
                    self.db.execute("INSERT OR REPLACE INTO meta VALUES ('v', ?)", (SCAN_VERSION,))
                    self.db.execute("INSERT OR REPLACE INTO meta VALUES ('month', ?)", (month,))
        except BaseException:
            self.db.close()
            raise

    def _meta(self, k: str):
        row = self.db.execute("SELECT v FROM meta WHERE k = ?", (k,)).fetchone()
        return row[0] if row else None

    @contextmanager
    def tx(self):
        self.db.execute("BEGIN")
        try:
            yield
        except BaseException:
            self.db.execute("ROLLBACK")
            raise
        self.db.execute("COMMIT")

    def reset(self) -> None:
        """Forget everything: the month is read again from the first byte. Used when what the totals rest on is gone (a transcript replaced or
        removed: its messages cannot be taken out of the totals, nor the copies other transcripts skipped because of them put back)."""
        with self.tx():
            for t in ("tails", "tally", "ids", "files", "meta"):
                self.db.execute(f"DELETE FROM {t}")
            self.db.execute("INSERT INTO meta VALUES ('v', ?)", (SCAN_VERSION,))
            self.db.execute("INSERT INTO meta VALUES ('month', ?)", (self.month,))

    def settle(self, wanted: dict[str, str]) -> bool:
        """Start the whole month again (`reset`) when a transcript the cache holds is no longer one of `wanted` ({path: session id}), has been
        replaced (another inode) or has shrunk. True when it did. Rare: transcripts only grow."""
        for _fid, path, ino, off in self.db.execute("SELECT fid, path, ino, off FROM files").fetchall():
            try:
                st = os.stat(path)
            except OSError:
                st = None
            if path not in wanted or st is None or st.st_ino != ino or st.st_size < off:
                self.reset()
                return True
        return False

    def scan(self, path: Path, since_ms: float, timeline: "Timeline") -> int:
        """Bring one transcript up to its end; the bytes read."""
        key = str(path)
        st = path.stat()
        row = self.db.execute("SELECT fid, ino, off FROM files WHERE path = ?", (key,)).fetchone()
        if row is not None and row[2] >= st.st_size:
            return 0
        with self.tx():
            if row is None:
                fid = self.db.execute("INSERT INTO files(path, ino, off) VALUES (?, ?, 0)", (key, st.st_ino)).lastrowid
                off = 0
            else:
                fid, off = row[0], row[2]
            fold = _Folder(self.db, fid, timeline)
            pending = {mid: [ms, model, *tok] for mid, ms, model, *tok in
                       self.db.execute("SELECT mid, ms, model, t0, t1, t2, t3, t4 FROM tails WHERE fid = ?", (fid,))}
            pos = read_new(path, off, since_ms, pending, fold)
            fold.keep_open(pending)
            self.db.execute("UPDATE files SET off = ? WHERE fid = ?", (pos, fid))
        return pos - off

    def adopt_legacy(self, legacy: Path, wanted: dict[str, str], timelines: dict[str, "Timeline"]) -> bool:
        """Read the cache an earlier release kept as JSON ({"v": 1, "month", "files": {path: {"ino", "off", "recs": {id: [ms, model, five counts]}}}})
        into this one, once, and remove it: its transcripts keep the offset they were read to, so nothing is read again. Only for a cache with
        nothing in it yet. The file is read whole (the old release held it whole too, under its own cap), but one past LEGACY_MAX_BYTES is not:
        it is dropped and the month is read again; so is one of another month or version or that is not JSON. True when messages were adopted."""
        if not self.fresh:
            return False
        adopted = False
        try:
            size = legacy.stat().st_size
        except OSError:
            return False
        doc = None
        if size <= LEGACY_MAX_BYTES:
            try:
                doc = json.loads(legacy.read_text())
            except (OSError, ValueError, RecursionError):
                doc = None
        files = doc.get("files") if isinstance(doc, dict) and doc.get("v") == 1 and doc.get("month") == self.month else None
        if isinstance(files, dict):
            with self.tx():
                for key in sorted(files):   # the first transcript by path keeps a message, as the old release counted it
                    e = files[key]
                    sid = wanted.get(key)
                    recs = e.get("recs") if isinstance(e, dict) else None
                    if sid is None or not isinstance(recs, dict) or not isinstance(e.get("ino"), int) or not isinstance(e.get("off"), int):
                        continue
                    fid = self.db.execute("INSERT INTO files(path, ino, off) VALUES (?, ?, ?)", (key, e["ino"], e["off"])).lastrowid
                    fold = _Folder(self.db, fid, timelines[sid])
                    pending = {}
                    for mid, r in recs.items():
                        if (isinstance(mid, str) and isinstance(r, list) and len(r) == 7 and isinstance(r[1], str)
                                and all(isinstance(x, (int, float)) and 0 <= x < _TOKEN_MAX for x in (r[0], *r[2:]))):
                            pending[mid] = [int(r[0]), r[1], *[int(x) for x in r[2:]]]
                            adopted = True
                            while len(pending) > PENDING_MAX:
                                k = next(iter(pending))
                                fold(k, pending.pop(k))
                    fold.keep_open(pending)
        doc = files = None
        try:
            legacy.unlink()
        except OSError:
            pass
        self.fresh = False
        return adopted

    def check_size(self) -> None:
        """The cache file is held under MAX_STORE_BYTES: past it the count says so in plain words rather than fill the disk."""
        pages = self.db.execute("PRAGMA page_count").fetchone()[0] - self.db.execute("PRAGMA freelist_count").fetchone()[0]
        if pages * self.db.execute("PRAGMA page_size").fetchone()[0] > MAX_STORE_BYTES:
            raise SpendError("there are too many messages to count")

    def totals(self, wanted: dict[str, str], timelines: dict[str, "Timeline"]):
        """The month's figures, one row at a time: (session id, lane, model, messages, five token counts) for each transcript of `wanted`
        ({path: session id}), each lane and each model, with the transcript's open messages added (the ones no other transcript has closed; the first
        transcript by path keeps a message two hold open). Only the lanes of LANES; the model as `normalize_model` writes it."""
        for path, lane, model, calls, *tok in self.db.execute(
                "SELECT f.path, t.lane, t.model, t.calls, t.t0, t.t1, t.t2, t.t3, t.t4 FROM tally t JOIN files f ON f.fid = t.fid ORDER BY f.path, t.lane, t.model"):
            if path in wanted:
                yield wanted[path], lane, model, calls, tok
        seen: set[str] = set()   # the open messages of all transcripts: a few per transcript that grew lately
        for path, mid, ms, model, *tok in self.db.execute(
                "SELECT f.path, t.mid, t.ms, t.model, t.t0, t.t1, t.t2, t.t3, t.t4 FROM tails t JOIN files f ON f.fid = t.fid "
                "WHERE NOT EXISTS (SELECT 1 FROM ids i WHERE i.mid = t.mid) ORDER BY f.path, t.mid"):
            if path not in wanted or mid in seen:
                continue
            seen.add(mid)
            lane = timelines[wanted[path]].lane_at(ms / 1000.0)
            if lane in LANES:
                yield wanted[path], lane, normalize_model(model), 1, tok

    def close(self) -> None:
        self.db.close()


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


# ── the API spend limit (the aws-platform card's strip) ──────────────────────
LIMIT_FILE = "aws-api-limit.json"   # in sala's state dir; written by contrib/briefing/aws-limit.sh (aws_limit.py), never by this app
LIMIT_STALE_S = 14 * 86400          # an email older than this is shown as "as of <date>, no newer email"
LIMIT_MAX = 1e9                     # a limit at or above this (or not a finite number) is a corrupt file, not a figure
TIER_MAX = 1000


def _org_key(name: object) -> str:
    """An organization name as the job compares it (aws_limit.py _org_key): whitespace collapsed, edge punctuation off, case folded."""
    return " ".join(str(name or "").split()).strip(" .,;:").casefold()


def read_api_limit(path: Path | None, now: datetime | None = None, org: str | None = None) -> dict | None:
    """The limit, tier and pause date from the state file the job keeps from Anthropic's "Monthly Claude API Spend Exceeding
    Thresholds" emails, or None for a file that is missing, unreadable or does not hold all of them (the card then shows no strip,
    never an error). The facts are the email's own: nothing is computed from them except two flags for the card, evaluated now:
    `stale` (the newest email is more than 14 days old: the figures stay, marked as of that email) and `pauseEnded` (the pause-until
    instant has passed). Times are ISO UTC; the card shows them in the SALA_TZ zone.
    The file counts only for the organization the job is set to read: `org` (default: SALA_AWS_LIMIT_ORG, from the environment or sala's
    config, read now) must be set and name the file's own "org" (compared as the job compares: case, spacing and edge punctuation aside);
    with the setting cleared or changed the file is another organization's and the answer is None. Numbers must be finite and sane
    (a limit above 0 and below 1e9, a tier of 0 to 1000): a corrupt file never becomes a figure, and never an error."""
    if path is None:
        return None
    if org is None:
        from .config import sala_setting
        org = sala_setting("SALA_AWS_LIMIT_ORG")
    if not _org_key(org):
        return None
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, RecursionError):   # RecursionError: a deeply nested file (100000 "[") overflows the parser
        return None
    if not isinstance(doc, dict) or doc.get("v") != 1:
        return None
    file_org = doc.get("org")
    if not isinstance(file_org, str) or _org_key(file_org) != _org_key(org):
        return None
    limit, tier = doc.get("limit"), doc.get("tier")
    # a chained comparison is false for NaN and for infinity (1e309 reads as inf), and compares a huge int without converting it
    if isinstance(limit, bool) or not isinstance(limit, (int, float)) or not 0 < limit < LIMIT_MAX:
        return None
    if isinstance(tier, bool) or not isinstance(tier, int) or not 0 <= tier <= TIER_MAX:
        return None
    until, sent = parse_iso(doc.get("paused_until")), parse_iso(doc.get("email_date"))
    if until is None or sent is None:
        return None
    fetched = doc.get("fetched_at")
    t = (now or datetime.now(timezone.utc)).timestamp()
    age = t - sent
    return {
        "limit": limit,
        "tier": tier,
        "pausedUntil": doc["paused_until"],
        "emailDate": doc["email_date"],
        "fetchedAt": fetched if isinstance(fetched, str) and parse_iso(fetched) is not None else None,
        "org": file_org,
        "stale": age > LIMIT_STALE_S,
        "staleDays": max(0, int(age // 86400)),
        "pauseEnded": t >= until,
    }


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


def _count(scan_path: Path | None, month: str, since_ms: float, sids: list[str], files: dict[str, list[Path]],
           lanes_of_sid: dict[str, "Timeline"]) -> tuple[dict, int, set[str]]:
    """Bring the cache up to the transcripts' ends and add its totals up: ({lane: {usd, calls, models, sessions, unpriced}}, the bytes read, the
    sessions with a transcript read). The totals are read from the cache one row at a time (the count holds no list of messages)."""
    wanted = {str(p): sid for sid, ps in files.items() for p in ps}
    store = ScanStore(scan_path, month)
    try:
        if scan_path is not None:
            store.adopt_legacy(scan_path.with_name(LEGACY_SCAN_FILE), wanted, lanes_of_sid)
        store.settle(wanted)
        scanned = 0
        found: set[str] = set()
        for sid in sids:
            for p in files[sid]:
                try:
                    scanned += store.scan(p, since_ms, lanes_of_sid[sid])
                except OSError:
                    del wanted[str(p)]   # gone since it was listed: not counted this time
                    continue
                found.add(sid)
            store.check_size()
        acc = {lane: {"usd": 0.0, "calls": 0, "models": {}, "sessions": {}, "unpriced": {}} for lane in LANES}
        for sid, lane, model, calls, tok in store.totals(wanted, lanes_of_sid):
            a = acc[lane]
            usd = price(model, tok)
            a["calls"] += calls
            s = a["sessions"].setdefault(sid, {"usd": 0.0, "calls": 0})
            s["calls"] += calls
            if usd is None:
                u = a["unpriced"].setdefault(model, {"calls": 0, "tokens": 0})
                u["calls"] += calls
                u["tokens"] += sum(tok)
                continue
            a["usd"] += usd
            s["usd"] += usd
            m = a["models"].setdefault(model, {"usd": 0.0, "calls": 0})
            m["usd"] += usd
            m["calls"] += calls
        return acc, scanned, found
    finally:
        store.close()


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
    lanes_of_sid = {i: facts.timeline(i) for i in sids}
    files = {sid: transcript_files(projects, sid, start.timestamp()) for sid in sids}
    try:
        acc, scanned, found = _count(scan_path, month, since_ms, sids, files, lanes_of_sid)
    except sqlite3.DatabaseError as e:
        # a cache file that is not a database (or a damaged one) is only a cache: dropped, and the month read again once. Anything else
        # (a full disk, a lock another process holds: OperationalError) is not that, and is reported as it is.
        if type(e) is not sqlite3.DatabaseError or scan_path is None:
            raise
        for suffix in ("", "-journal", "-wal", "-shm"):
            with contextlib.suppress(OSError):
                scan_path.with_name(scan_path.name + suffix).unlink()
        acc, scanned, found = _count(scan_path, month, since_ms, sids, files, lanes_of_sid)

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
        self.scan_path = sd / SCAN_FILE
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
