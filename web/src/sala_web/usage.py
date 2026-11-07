"""The Overview's Usage analysis tab: what the Claude Code replies on this machine cost, AT LIST PRICES, by week, day, lane, model, project,
agent and folder. One data layer under three views of the tab (Report, Explorer, Digest); `GET /api/usage?week=<0|1|2>` serves it.

WHERE THE FIGURES COME FROM. Nothing is asked of Anthropic or AWS: every assistant reply in a Claude Code transcript carries
message.usage (input, output, cache-read and the two cache-write tiers), which is multiplied by the model's list price. The count
is spend.py's, reused rather than copied: the same price table (spend.PRICES, ONE place), the same model-name normalizer, the same
rule that a reply is counted once (a streamed reply is several lines with one message id, a fork copies history: each id once,
the largest of every token field, the first file by path keeps it), the same reading of subagent transcripts (they belong to the
session whose folder holds them) and the same lane records (spend.Facts: lanes.log, the live processes, the registry, lanes.tsv).
What differs is the reach: spend.py reads only the sessions that are or were on an AWS lane, this reads every transcript of the
last three weeks, under the default config directory and under each second login's (sessions.LANE_DIRS, whose lane is fixed).
Only THIS machine's transcripts are read; the tab says so.

THE WEEKS. A week runs from one weekly reset of the subscription lane to the next (the "This week" limit's `resetsAt`, read from
the quota cache the lane cards use, quota.py): week 0 is the one now running, 1 and 2 are seven days back each. A reset time that
has passed (the quota answer is old) is rolled forward by whole weeks; with no quota answer at all the last anchor this module saved
is used, and with none the weeks are plain seven-day windows ending now (`resetKnown` false). Days are KST (Asia/Seoul), always.

THE ROWS. One row per (week, day, lane, model, project, agent, folder): dollars, replies and the five token counts. The tokens are
kept on record and never shown by the page. A model with no price is counted with $0 and listed in `unpriced`, never silently.
  - lane: the lane at the reply's time (spend.Facts timeline), or the second login's fixed lane;
  - agent: the session's name in sala's registry (a rename counts under the current name), "(unnamed)" for a session it does not know;
  - project: the agent's name up to the project part. Sessions are named <scope>-<project>-…, the scopes being this box's
    (scopes.py), so `<scope>-<project>`; a name whose first part is no scope has its first part. "(unnamed)" stays "(unnamed)";
  - folder: the directory the transcript's session started in (the first `cwd` the transcript names, else the folder name Claude Code
    made), a worktree under <dir>/.claude/worktrees/<name> counted as <dir>, the home directory written "~".
No prompt, reply text, tool input or secret leaves a transcript: the answer holds names, counts and dollars.

KEEPING IT CHEAP. Per transcript the cache holds the inode, the size and mtime last seen, the offset after its last complete line, its
first `cwd` and its replies in the window as {message id: [epoch ms, model, five token counts]}. A file whose size and mtime are as they were is not
opened; one that grew is read from where it stopped; a file replaced or shrunk is read again. The cache lives in memory and in
usage-scan.json (saved when a scan found something new, at most every SAVE_EVERY seconds, and at the end of a first scan). The
answer is served at once from the last good one and refreshed in a thread once it is TTL old (swr.py, the lane cards' way);
with no answer yet it is {"pending": true} and the page asks again.

THE REPLIES (Explorer's drill-down). `GET /api/usage/replies?week=&<dimension>=<value>…` lists the single replies behind a filter, newest first, capped
(REPLIES_CAP) with the count and the dollars of ALL that match. It reads no transcript: the count that makes the rows above also leaves, in the scan holder,
one small record per reply (its epoch ms, the index of its row key and its dollars), so a drill-down is a pass over memory. Time, lane, model, project,
agent and folder only: still no prompt, reply text or token count. After a restart the rows are served at once from usage-answer.json while the
replies are not yet there: the endpoint then answers {"pending": true} and makes the next count due, as the first request of a fresh server does.
"""

from __future__ import annotations

import asyncio
import heapq
import json
import os
import re
import time
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Awaitable, Callable

from . import lanenames as LNM
from . import lanestate as LS
from . import quota as Q
from . import scopes as SC
from . import sessions as S
from . import spend as SPD
from . import swr as SWR

TTL = 60.0              # one count a minute, however many pages ask
ERROR_RETRY = 60.0
SCAN_VERSION = 1
SAVE_EVERY = 600.0      # the scan cache is written at most this often (it is tens of MB); a scan that read a lot also saves at its end
MAX_RECORDS = 1_000_000  # replies kept; more is an error on the tab, not a slow crash
WEEKS = 3
READ_MARGIN = 3600.0    # seconds the transcript read reaches back of the oldest week
WEEK_S = 7 * 86400
KST = timezone(timedelta(hours=9))
TZ_NAME, TZ_LABEL = "Asia/Seoul", "KST"
UNNAMED = "(unnamed)"
REPLIES_CAP = 200       # a drill-down names this many replies at most (the newest); the answer says how many there are in all
REPLY_FIELDS = ["time", "day", "lane", "model", "project", "agent", "folder", "usd"]   # the order of a reply; time = KST 'YYYY-MM-DDTHH:MM:SS'
REPLY_DIMS = ("day", "lane", "model", "project", "agent", "folder")   # what a drill-down can filter on (a row key's columns after the week)
FIELDS = ["day", "lane", "model", "project", "agent", "folder", "usd", "replies", "tokens"]   # the order of a row; tokens = [input, cache write 5m, cache write 1h, cache read, output]
WEEKLY_LABEL = Q.limit_label({"kind": "weekly_all"})   # the quota answer's name for the all-models weekly limit

_SCOPE_ALL = re.compile(r"[^A-Za-z0-9]")
_CWD = re.compile(rb'"cwd"\s*:\s*"((?:[^"\\]|\\.)*)"')
_DAYS: dict[int, str] = {}


# ── time ──────────────────────────────────────────────────────────────────────
def day_of(t: float) -> str:
    """The KST calendar day of an epoch second, 'YYYY-MM-DD' (KST has no daylight saving: a fixed +9 h)."""
    n = int((t + 9 * 3600) // 86400)
    d = _DAYS.get(n)
    if d is None:
        d = _DAYS[n] = date.fromordinal(n + 719163).isoformat()   # day 0 of the epoch is ordinal 719163
    return d


def kst_minute(t: float) -> str:
    return datetime.fromtimestamp(t, KST).strftime("%Y-%m-%dT%H:%M")


def weekly_limit(answer: dict | None) -> dict | None:
    """The all-models weekly limit of a quota answer ({label, percent, resetsAt}), or None."""
    for lim in (answer or {}).get("limits") or []:
        if isinstance(lim, dict) and lim.get("label") == WEEKLY_LABEL:
            return lim
    return None


def reset_epoch(lim: dict | None) -> float | None:
    return SPD.parse_iso(lim.get("resetsAt")) if lim else None


def week_bounds(reset: float | None, now: float) -> tuple[list[tuple[float, float]], bool]:
    """([(start, end) epoch seconds of week 0, 1, 2], whether the weekly reset is known). `reset` is a reset time; one that has passed is rolled
    forward by whole weeks until it is ahead. Without one the weeks are seven-day windows ending now."""
    known = reset is not None
    end = float(reset) if known else float(now)
    if known:
        while end <= now:
            end += WEEK_S
        while end - WEEK_S > now:
            end -= WEEK_S
    return [(end - WEEK_S * (i + 1), end - WEEK_S * i) for i in range(WEEKS)], known


def days_between(start: float, end: float) -> list[str]:
    """The KST days a week touches, first to last (the day a week ends at midnight sharp is not one of them)."""
    a, b = datetime.fromtimestamp(start, KST), datetime.fromtimestamp(end, KST)
    out, x = [], a.date()
    while x <= b.date():
        if not (x == b.date() and b.hour == 0 and b.minute == 0):
            out.append(x.isoformat())
        x += timedelta(days=1)
    return out


# ── names ─────────────────────────────────────────────────────────────────────
def project_of(agent: str, scopes: list[str]) -> str:
    """The project part of an agent's name (module docstring). With no scopes configured, a name of three parts or more keeps its first two."""
    if agent == UNNAMED:
        return UNNAMED
    parts = agent.split("-")
    if len(parts) > 1 and parts[1] and (parts[0] in scopes or (not scopes and len(parts) > 2)):
        return parts[0] + "-" + parts[1]
    return parts[0] or agent


def folder_of(cwd: str | None, dirname: str, home: str) -> str:
    """The folder a session ran in, for the Folder column. cwd is the transcript's own first `cwd`; without one the folder name Claude Code made
    (the path with every other character turned into '-') is matched against the home directory, and anything else is shown as that name."""
    if cwd and cwd.startswith("/"):
        p = cwd.rstrip("/") or "/"
        i = p.find("/.claude/worktrees/")
        if i > 0:
            p = p[:i]
        h = home.rstrip("/")
        if p == h:
            return "~"
        if h and p.startswith(h + "/"):
            return "~/" + p[len(h) + 1:]
        return p
    enc = _SCOPE_ALL.sub("-", home.rstrip("/"))
    d = dirname
    i = d.find("--claude-worktrees-")
    if i > 0:
        d = d[:i]
    if d == enc:
        return "~"
    if enc and d.startswith(enc + "-"):
        return d[len(enc) + 1:]
    return d.lstrip("-") or "~"


# ── reading a transcript ──────────────────────────────────────────────────────
class Reader:
    """Reads the replies of transcripts into the cache. Model names are normalized once per distinct raw name."""

    def __init__(self) -> None:
        self.models: dict[str, str] = {}

    def model(self, raw: str) -> str:
        m = self.models.get(raw)
        if m is None:
            m = self.models[raw] = SPD.normalize_model(raw)
        return m

    def read_new(self, path: Path, entry: dict, since_ms: float) -> int:
        """Read what was appended since entry["off"] (only whole lines: a line still being written is read next time). Returns the bytes read.
        A reply seen again keeps the larger of each count."""
        recs = entry["recs"]
        with open(path, "rb") as fh:
            fh.seek(entry["off"])
            pos = entry["off"]
            for raw in fh:
                if not raw.endswith(b"\n"):
                    break
                pos += len(raw)
                if entry["cwd"] is None and b'"cwd"' in raw:
                    m = _CWD.search(raw)
                    if m:
                        try:
                            entry["cwd"] = json.loads(b'"' + m.group(1) + b'"')
                        except ValueError:
                            pass
                if b'"usage"' not in raw or b'"assistant"' not in raw:
                    continue
                try:
                    d = json.loads(raw)
                except ValueError:
                    continue
                if not isinstance(d, dict) or d.get("type") != "assistant":
                    continue
                msg = d.get("message")
                if not isinstance(msg, dict) or not isinstance(msg.get("usage"), dict):
                    continue
                model = msg.get("model")
                mid = msg.get("id") or d.get("requestId")
                t = SPD.parse_iso(d.get("timestamp"))
                if not mid or not isinstance(model, str) or model == "<synthetic>" or t is None or t * 1000 < since_ms:
                    continue
                tok = SPD.usage_tokens(msg["usage"])
                old = recs.get(mid)
                if old is not None:
                    tok = [max(a, b) for a, b in zip(old[2:], tok)]
                recs[mid] = [int(t * 1000), self.model(model), *tok]
            n = pos - entry["off"]
            entry["off"] = pos
            return n


class ScanCache:
    """Per transcript: inode, size, mtime, offset, first cwd and the window's replies. In memory, and in a file in the state dir."""

    def __init__(self, path: Path | None, since_ms: float):
        self.path = path
        self.since_ms = since_ms
        self.files: dict[str, dict] = {}
        self.dirty = False
        self.saved_at = 0.0
        self.reader = Reader()
        if path is None:
            return
        try:
            doc = json.loads(path.read_text())
        except (OSError, ValueError):
            return
        if isinstance(doc, dict) and doc.get("v") == SCAN_VERSION and isinstance(doc.get("since"), (int, float)) and doc["since"] <= since_ms \
                and isinstance(doc.get("files"), dict):
            self.files = {k: v for k, v in doc["files"].items() if isinstance(v, dict) and isinstance(v.get("recs"), dict)}
            self.since_ms = doc["since"]   # the window the replies were kept for: wider than asked is fine, narrower is rebuilt below
            self.saved_at = time.monotonic()

    def widen_to(self, since_ms: float) -> None:
        """The window now reaches back further than the cache was built for (a reset moved earlier): read everything again."""
        if since_ms < self.since_ms:
            self.files, self.since_ms, self.dirty = {}, since_ms, True

    def scan(self, path: Path) -> int:
        """Bring one transcript's entry up to its end; the bytes read. A file that shrank or was replaced is read again from 0."""
        key = str(path)
        st = path.stat()
        e = self.files.get(key)
        if e is not None and e.get("ino") == st.st_ino and e.get("size") == st.st_size and e.get("mtime") == st.st_mtime_ns:
            return 0
        if e is None or e.get("ino") != st.st_ino or e.get("off", 0) > st.st_size:
            e = self.files[key] = {"ino": st.st_ino, "size": 0, "mtime": 0, "off": 0, "cwd": None, "recs": {}}
        n = self.reader.read_new(path, e, self.since_ms)
        e["size"], e["mtime"] = st.st_size, st.st_mtime_ns
        self.dirty = True
        return n

    def records(self) -> int:
        return sum(len(e["recs"]) for e in self.files.values())

    def save(self, force: bool = False) -> None:
        if self.path is None or not self.dirty:
            return
        if not force and time.monotonic() - self.saved_at < SAVE_EVERY:
            return
        try:
            SWR.write_atomic(self.path, {"v": SCAN_VERSION, "since": self.since_ms, "files": self.files})
        except OSError:
            return
        self.dirty = False
        self.saved_at = time.monotonic()


def transcript_files(root: Path, since: float) -> list[tuple[Path, str, str]]:
    """[(path, folder name, session id)] of every transcript under a projects directory modified since `since`, subagents included. A file in
    another place than <folder>/<id>.jsonl or <folder>/<id>/subagents/**.jsonl is not a transcript."""
    out = []
    try:
        folders = [p for p in root.iterdir() if p.is_dir()]
    except OSError:
        raise SPD.SpendError("the transcripts folder could not be read") from None
    for folder in folders:
        try:
            with os.scandir(folder) as it:
                entries = list(it)
        except OSError:
            continue
        for e in entries:
            try:
                if e.is_file() and e.name.endswith(".jsonl"):
                    if e.stat().st_mtime >= since:
                        out.append((Path(e.path), folder.name, e.name[:-6]))
                elif e.is_dir():
                    sub = Path(e.path) / "subagents"
                    if sub.is_dir():
                        for p in sub.rglob("*.jsonl"):
                            if p.stat().st_mtime >= since:
                                out.append((p, folder.name, e.name))
            except OSError:
                continue
    return out


# ── the count ─────────────────────────────────────────────────────────────────
def lane_records(rows: list[dict], names: list[dict], account_lanes: set[str], seen: set[str]) -> dict[str, dict]:
    """{lane code: {label, billing, known}} for every lane in sala's lane table (`sala lane --json`, lanes.parse_table) and every lane a
    reply was counted on. billing is the table's word: "subscription" is a flat plan, "usage" is billed per use. A lane the table does not
    list (or no table at all) has none: an account lane is then taken as a subscription and any other as usage, and `known` says so."""
    out: dict[str, dict] = {}
    for r in rows:
        code = LS.norm(r.get("id"))
        if isinstance(code, str) and code:
            b = r.get("billing")
            out[code] = {"billing": b if b in ("subscription", "usage") else None}
    for code in seen:
        out.setdefault(code, {"billing": None})
    for code, v in out.items():
        v["label"] = LNM.label(names, code) if names else code
        v["known"] = v["billing"] is not None
        if v["billing"] is None:
            v["billing"] = "subscription" if code in account_lanes else "usage"
    return out


def compute(settings, live: list, lane_rows: list[dict], lane_names: list[dict], quota: list[dict], now: float,
            holder: dict, observed_path: Path | None, anchor: float | None) -> dict:
    """The answer for all three weeks (blocking: run it in a thread; `holder` keeps the scan cache between counts). Raises SpendError. `quota` is the quota cache's answers (a list of
    {lane, limits…}); `anchor` the last weekly reset this module saved (used when the quota has none)."""
    t0 = time.monotonic()
    home = str(Path.home())
    account_lanes = {"subscription-1", *[LS.norm(k) for k in _login_lanes()]}
    sub1 = next((a for a in quota if LS.norm(a.get("lane")) == "subscription-1"), None)
    reset = reset_epoch(weekly_limit(sub1))
    if reset is None and anchor is not None:
        reset = anchor
    if reset is not None:
        reset = round(reset / 60) * 60   # a reset is on the minute; the quota answer's fractions of a second move from one answer to the next
    bounds, known = week_bounds(reset, now)
    since = bounds[-1][0]
    since_ms = (since - READ_MARGIN) * 1000   # the scan cache reaches an hour back of the oldest week, so a reset moving a little never rebuilds it

    cache = holder.get("scan")   # kept between counts: the scan cache file is tens of MB, read once per process
    if cache is None:
        cache = holder["scan"] = ScanCache(holder.get("path"), since_ms)
    cache.widen_to(since_ms)
    observed = SPD.load_observed(observed_path)
    facts = SPD.Facts(settings.sala_state_dir, live, observed)
    roots, seen_roots = [], set()
    for root, fixed in [(settings.projects_dir, None), *[(d / "projects", LS.norm(lane)) for lane, d in _login_dirs().items()]]:
        real = root.resolve()
        if real not in seen_roots:   # a second login's projects folder is often a link to the main one: read it once, its lane from the records
            seen_roots.add(real)
            roots.append((root, fixed))
    scanned = 0
    wanted: dict[str, tuple[str, str | None, str]] = {}   # path -> (folder name, fixed lane, session id)
    for root, fixed in roots:
        if not root.is_dir():
            continue
        for p, folder, sid in transcript_files(root, since):
            try:
                scanned += cache.scan(p)
            except OSError:
                continue
            wanted[str(p)] = (folder, fixed, sid)
        if cache.records() > MAX_RECORDS:
            raise SPD.SpendError("there are too many replies to count")
    for k in [k for k in cache.files if k not in wanted]:   # a transcript no longer in the window is dropped
        del cache.files[k]
        cache.dirty = True
    cache.save(force=scanned > 50_000_000)

    # one reply once, whichever file holds it: the largest of each count, the first file by path keeps it (spend.py's rule)
    merged: dict[str, list] = {}
    for path in sorted(wanted):
        folder, fixed, sid = wanted[path]
        e = cache.files.get(path)
        if e is None:
            continue
        where = (sid, fixed, folder_of(e.get("cwd"), folder, home))
        for mid, r in e["recs"].items():
            old = merged.get(mid)
            if old is None:
                merged[mid] = [where, r[0], r[1], list(r[2:])]
            elif r[2:] != old[3]:   # a fork copies history: the same counts, as a rule
                old[3] = [max(a, b) for a, b in zip(old[3], r[2:])]

    scopes = SC.names()
    timelines: dict[str, object] = {}
    agg: dict[tuple, list] = {}
    unpriced: dict[str, int] = {}
    totals = [0.0] * WEEKS
    counts = [0] * WEEKS
    lane_totals: dict[int, dict[str, float]] = {i: {} for i in range(WEEKS)}
    ends = [b[1] for b in bounds]
    starts = [b[0] for b in bounds]
    elapsed = now - starts[0]
    same_prev = 0.0   # week 1's dollars over the same hours that week 0 has run so far
    names: dict[str, tuple[str, str]] = {}
    key_ids: dict[tuple, int] = {}   # row key -> its index; and one (ms, key index, dollars) per reply: the drill-down's records (module docstring)
    recs: list[tuple] = []
    for (sid, fixed, folder), ms, model, tok in merged.values():
        t = ms / 1000.0
        wk = 0 if t >= starts[0] else 1 if t >= starts[1] else 2 if t >= starts[2] else -1
        if wk < 0 or t >= ends[0]:   # before the oldest week, or after the running week's end (a reset not rolled forward yet)
            continue
        if fixed:
            lane = fixed
        else:
            tl = timelines.get(sid)
            if tl is None:
                tl = timelines[sid] = facts.timeline(sid)
            lane = tl.lane_at(t)
        rate = SPD.PRICES.get(model)   # the model is already normalized (Reader.model)
        if rate is None:
            unpriced[model] = unpriced.get(model, 0) + 1
            usd = 0.0
        else:
            usd = (tok[0] * rate[0] + tok[1] * rate[1] + tok[2] * rate[2] + tok[3] * rate[3] + tok[4] * rate[4]) / 1e6
        nm = names.get(sid)
        if nm is None:
            agent = facts.shown.get(sid) or UNNAMED
            nm = names[sid] = (agent, project_of(agent, scopes))
        key = (wk, day_of(t), lane, model, nm[1], nm[0], folder)
        kid = key_ids.get(key)
        if kid is None:
            kid = key_ids[key] = len(key_ids)
        recs.append((ms, kid, usd))
        a = agg.get(key)
        if a is None:
            a = agg[key] = [0.0, 0, [0, 0, 0, 0, 0]]
        a[0] += usd
        a[1] += 1
        tk = a[2]
        for i in range(5):
            tk[i] += tok[i]
        totals[wk] += usd
        counts[wk] += 1
        lane_totals[wk][lane] = lane_totals[wk].get(lane, 0.0) + usd
        if wk == 1 and t < starts[1] + elapsed:
            same_prev += usd

    rows = [[wk, day, lane, model, project, agent, folder, round(v[0], 4), v[1], v[2]]
            for (wk, day, lane, model, project, agent, folder), v in sorted(agg.items())]
    seen = {r[2] for r in rows}
    lanes = lane_records(lane_rows, lane_names, account_lanes, seen)
    flat = {c for c, v in lanes.items() if v["billing"] == "subscription"}
    weeks = []
    for i, (a, b) in enumerate(bounds):
        weeks.append({"id": i, "start": int(a), "end": int(b), "startKst": kst_minute(a), "endKst": kst_minute(b), "days": days_between(a, b),
                      "current": i == 0, "total": round(totals[i], 4), "billed": round(sum(v for c, v in lane_totals[i].items() if c not in flat), 4),
                      "replies": counts[i]})
    used = sorted({r[3] for r in rows})
    prices = {m: dict(zip(("input", "cacheWrite5m", "cacheWrite1h", "cacheRead", "output"), SPD.PRICES[m])) for m in used if m in SPD.PRICES}
    quotas = {}
    for a in quota:
        lane = LS.norm(a.get("lane"))
        lim = weekly_limit(a)
        r_at = reset_epoch(lim)
        if lim and isinstance(lim.get("percent"), (int, float)) and r_at is not None and r_at > now:
            quotas[lane] = {"percent": lim["percent"], "resetsAt": int(r_at)}
    out_lanes = [{"code": c, "label": v["label"], "billing": v["billing"], "flat": c in flat, "known": v["known"], "quota": quotas.get(c)}
                 for c, v in sorted(lanes.items(), key=lambda kv: (kv[0] not in seen, kv[0]))]
    holder["replies"] = {"generated": int(now), "keys": list(key_ids), "recs": recs}   # replaced whole, never changed in place: the endpoint reads it from another thread
    return {
        "tz": TZ_NAME, "tzLabel": TZ_LABEL, "resetKnown": known, "generated": int(now),
        "anchor": int(bounds[0][1]) if known else None,
        "weeks": weeks, "lanes": out_lanes, "fields": FIELDS, "rows": rows,
        "sameHours": {"prevTotal": round(same_prev, 4), "elapsedH": round(elapsed / 3600, 1)},
        "unpriced": sorted(({"model": m, "replies": n} for m, n in unpriced.items()), key=lambda x: (-x["replies"], x["model"])),
        "prices": {"asOf": SPD.PRICES_AS_OF, "unit": "USD per million tokens", "models": prices},
        "scannedBytes": scanned, "transcripts": len(wanted), "replies": sum(counts), "tookS": round(time.monotonic() - t0, 2),
    }


def _login_dirs() -> dict:
    return dict(S.LANE_DIRS)


def _login_lanes() -> list[str]:
    return list(_login_dirs())


# ── serving it ────────────────────────────────────────────────────────────────
def select_week(state: dict, week: int) -> dict:
    """The answer for one week: the rows of that week (their week column dropped) and everything else as it is."""
    out = {k: v for k, v in state.items() if k not in ("rows", "sameHours", "scannedBytes", "transcripts", "tookS")}
    out["week"] = week
    out["now"] = int(time.time())   # the server's clock, for "resets in" and "counted 3 min ago" (the page's own clock is not trusted)
    out["rows"] = [r[1:] for r in state.get("rows") or [] if r[0] == week]
    if week == 0:
        out["sameHours"] = state.get("sameHours")
    return out


def reply_list(store: dict, week: int, where: dict[str, list[str]], limit: int = REPLIES_CAP) -> dict:
    """The replies of one week that match `where` ({dimension: [accepted values]}; a dimension not named matches anything, several values of one
    dimension are alternatives), newest first, at most `limit` of them. `total` and `usd` count every match, so a capped list says what it leaves out."""
    limit = max(1, min(int(limit), REPLIES_CAP))
    keys = store["keys"]
    col = {d: i + 1 for i, d in enumerate(REPLY_DIMS)}   # a row key is (week, day, lane, model, project, agent, folder)
    want = {d: set(v) for d, v in where.items() if d in col and v}
    ok = {i for i, k in enumerate(keys) if k[0] == week and all(k[col[d]] in vs for d, vs in want.items())}
    total, usd, hits = 0, 0.0, []
    for r in store["recs"]:
        if r[1] in ok:
            total += 1
            usd += r[2]
            hits.append(r)
    rows = []
    for ms, kid, v in heapq.nlargest(limit, hits, key=lambda r: r[0]):
        k = keys[kid]
        rows.append([datetime.fromtimestamp(ms / 1000, KST).strftime("%Y-%m-%dT%H:%M:%S"), k[1], k[2], k[3], k[4], k[5], k[6], round(v, 6)])
    return {"week": week, "generated": store["generated"], "tz": TZ_NAME, "tzLabel": TZ_LABEL, "fields": REPLY_FIELDS, "total": total, "usd": round(usd, 4),
            "shown": len(rows), "capped": total > len(rows), "cap": REPLIES_CAP, "rows": rows}


class UsageCache:
    """The usage answer for all three weeks, served at once from the last good one (memory, and a file in the state dir so a restart has it) and
    refreshed in a thread once it is TTL old (swr.py). With no answer yet it is {"pending": true}. A failure keeps the last answer and adds
    `error` in plain words. The file holds names, counts and dollars only."""

    def __init__(self, settings, live: Callable[[], list], lane_table: Callable[[], Awaitable[list]],
                 lane_names: Callable[[], Awaitable[list]], quota: Callable[[], Awaitable[list]]):
        sd = settings.state_dir
        self.settings = settings
        self.live, self.lane_table, self.lane_names, self.quota = live, lane_table, lane_names, quota
        self._holder: dict = {"path": sd / "usage-scan.json"}   # {"scan": the ScanCache once built}; only the count's thread touches it
        self.observed_path = sd / "spend-lanes.json"   # spend.py's sightings of live processes' lanes; read only here
        self._swr = SWR.Revalidating(sd / "usage-answer.json", TTL, ERROR_RETRY, {"weeks": [], "rows": [], "lanes": []},
                                     valid=lambda d: isinstance(d.get("weeks"), list) and isinstance(d.get("rows"), list))

    def get(self, week: int = 0, fresh: bool = False) -> dict:
        if fresh and not self._swr.running:
            self._swr.expire()
        out = self._swr.serve(self._refresh)
        return select_week(out, week) if not out.get("pending") else {**{k: v for k, v in out.items() if k not in ("rows",)}, "week": week, "rows": []}

    async def replies(self, week: int, where: dict[str, list[str]], limit: int = REPLIES_CAP) -> dict:
        """The replies behind a filter (`reply_list`). They need the count's own records: with none yet (a fresh server, or a restart that served the saved
        rows) the answer is {"pending": true} and a count is made due; a failed count with nothing to read is {"error": …}. The pass over the records runs in a thread."""
        out = self._swr.serve(self._refresh)
        store = self._holder.get("replies")
        if store is None:
            if out.get("error"):
                return {"week": week, "error": out["error"], "rows": []}
            if not self._swr.running:
                self._swr.expire()
                self._swr.serve(self._refresh)
            return {"pending": True, "week": week, "rows": []}
        return await asyncio.to_thread(reply_list, store, week, where, limit)

    async def _refresh(self) -> dict:
        try:
            async def safe(fn, default):
                try:
                    return await fn()
                except Exception:   # sala or the quota not answering is "not known", never a failed count
                    return default
            rows = await safe(self.lane_table, [])
            names = await safe(self.lane_names, [])
            quota = await safe(self.quota, [])
            live = await asyncio.to_thread(self.live)
            anchor = self._swr.state.get("anchor")
            return await asyncio.to_thread(compute, self.settings, live, rows, names, quota, time.time(), self._holder,
                                           self.observed_path, anchor if isinstance(anchor, (int, float)) else None)
        except SPD.SpendError as e:
            raise SWR.Failed(str(e)) from None
        except Exception as e:  # never str(e): an unexpected error could carry anything
            raise SWR.Failed(f"the usage could not be counted ({type(e).__name__})") from None
