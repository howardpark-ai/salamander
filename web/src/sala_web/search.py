"""Search over this machine's Claude Code transcripts (the Overview's Search tab, GET /api/search).

What it reads: every `*.jsonl` under the projects directory (`~/.claude/projects`): a session's own transcript
(`<project>/<claude session id>.jsonl`) and its subagents' (`<project>/<claude session id>/subagents/agent-*.jsonl`). It only
reads them: nothing here writes a transcript, the registry or anything else, and the request carries no path (the query is
text, the range is two numbers, the rest are on/off switches), so no part of a request ever reaches the file system as a name.

What it sends back: the matches only, as short snippets, never a transcript. At most CAP (200) are sent, newest first; the answer
says how many there were and that the list was cut. The query is a plain, case-insensitive substring match: every word you type
must appear in the same entry ("quoted words" stay one phrase). There is no regular expression anywhere, so no query can make the
matching itself slow.

Cost, measured on this box (a day is about 490 MB of transcripts, 75 MB of it text): a file last written before the range is
never opened; a line is looked at as bytes first (all the plain-ASCII words must be on it before it is parsed as JSON); a big file
is entered at the first line inside the range (a bisect on the timestamps), not read from its head; a search that runs past
DEADLINE_S stops and sends what it has, saying so.

Results belong to an agent by its permanent id: sala's registry (`sessions.json`, id minted once, a rename or a /clear never changes
it) lists each agent's Claude session ids (`transcripts`), so a transcript file finds its row, and the row's CURRENT name is the name
shown. A transcript with no row (a headless run, a session from before the registry) is its own agent, keyed `session:<claude session
id>` and named after it. Subagents belong to the agent that started them, and are marked as subagents.

Where a result opens: each carries `pos`, the byte offset of a line's start in the session's own transcript (the cursor
GET /api/s/<pid>/transcript?around= takes), and `target`, the uuid to light there. For an entry of the session's own transcript
that is the entry's line; for a subagent's, the Agent/Task tool call in the session's transcript that started the subagent, found
through the parent's record of it (the call's tool_result carries `toolUseResult.agentId`; spawn_points). `pos` is None when that
call is not found.

Role (front / background / unknown): the registry row's `role` when it has one (`spawn --role`); else what stackshot says of that
name (the project pages' agents map, the same answer the Overview's Role column shows: `roles`, a keeper counts as background);
else "unknown", which is its own bucket in the filter, never a dropped result. A subagent shows its agent's role.
"""

from __future__ import annotations

import heapq
import json
import os
import re
import time
from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from . import schedules as SCH
from . import transcript as TR

CAP = 200                 # matches sent back
DEADLINE_S = 20.0         # a search stops here and sends what it has
MAX_QUERY = 200           # characters
MAX_WORDS = 8
MAX_RANGE_S = 366 * 86400
SNIPPET_BEFORE = 80
SNIPPET_AFTER = 150
MAX_MARKS = 12
BISECT_MIN = 1 << 20      # a file smaller than this is read from its head
BISECT_STOP = 1 << 16     # the bisect stops when the window is this small
CHECK_EVERY = 512         # lines between two looks at the clock

AGENT_CATS = ("front", "back", "sub", "unknown")
KINDS = ("messages", "tools", "output", "thinking")
ROLE_OF = {"front": "front", "back": "back", "keeper": "back"}   # stackshot's keeper is a background session

TS_RE = re.compile(rb'"timestamp"\s*:\s*"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)')
SID_RE = re.compile(r"^[0-9A-Fa-f-]{8,64}$")


class SearchError(ValueError):
    """A request that cannot be answered as asked: the message is a plain sentence for the page."""


# ---------- the query ----------

def parse_words(q: str) -> list[str]:
    """The words of a query, lower-cased: split on white space, a "quoted phrase" stays one word. SearchError when there is none,
    or too many or too long."""
    q = (q or "").strip()
    if not q:
        raise SearchError("Type something to search for.")
    if len(q) > MAX_QUERY:
        raise SearchError(f"A search is at most {MAX_QUERY} characters.")
    words = [(a or b).strip().lower() for a, b in re.findall(r'"([^"]*)"|(\S+)', q)]
    words = [w for w in words if w]
    if not words:
        raise SearchError("Type something to search for.")
    if len(words) > MAX_WORDS:
        raise SearchError(f"A search is at most {MAX_WORDS} words; put a phrase in quotes to keep it as one.")
    return words


def _prefilter_words(words: list[str]) -> list[bytes]:
    """The words a raw transcript line can be tested for before it is parsed: plain printable ASCII with no quote or backslash (the
    two characters JSON writes differently), whose lower-case spelling is what the line is lower-cased to. Anything else is left
    to the parsed text."""
    return [w.encode("ascii") for w in words if w.isascii() and all(0x20 <= ord(c) < 0x7f and c not in '"\\' for c in w)]


def parse_when(value: str, zone) -> float:
    """A moment from the page: epoch seconds, or a date and time `2026-11-01T09:00` (what a date picker gives) read in `zone`, the
    zone every time on the page is in (SALA_TZ). SearchError for anything else."""
    try:
        return float(value)
    except ValueError:
        pass
    try:
        d = datetime.fromisoformat(value)
    except ValueError:
        raise SearchError("That date is not one a search can use.") from None
    return (d.replace(tzinfo=zone) if d.tzinfo is None else d).timestamp()


# ---------- the registry ----------

@dataclass
class Agent:
    key: str            # the permanent id: the registry row's id, else session:<claude session id>
    name: str
    role: str           # front | back | unknown
    live: bool
    registered: bool


def load_registry(path: Path) -> dict[str, dict]:
    """sala's session registry, {row id: row}; {} when the file is missing or unreadable (the search then names every agent by its
    Claude session id and finds no role)."""
    try:
        with open(path, encoding="utf-8") as f:
            rows = (json.load(f) or {}).get("sessions") or {}
    except (OSError, ValueError, AttributeError):
        return {}
    return {k: v for k, v in rows.items() if isinstance(v, dict)} if isinstance(rows, dict) else {}


def role_of(row: dict, roles: dict[str, dict]) -> str:
    """front | back | unknown for a registry row: its own role, else what stackshot says of its name (or an earlier name)."""
    own = ROLE_OF.get(str(row.get("role") or ""))
    if own:
        return own
    for name in [row.get("name"), *(row.get("aliases") or [])]:
        r = roles.get(name) if isinstance(name, str) else None
        found = ROLE_OF.get(str((r or {}).get("role") or "")) if isinstance(r, dict) else None
        if found:
            return found
    return "unknown"


class Directory:
    """Claude session id -> the Agent it belongs to, built once per search from the registry and the roles."""

    def __init__(self, registry: dict[str, dict], roles: dict[str, dict]):
        self.by_sid: dict[str, Agent] = {}
        for rid, row in registry.items():
            agent = Agent(key=str(row.get("id") or rid), name=str(row.get("name") or rid), role=role_of(row, roles),
                          live=row.get("state") == "live", registered=True)
            for t in row.get("transcripts") or []:
                sid = t.get("id") if isinstance(t, dict) else None
                if isinstance(sid, str) and sid:
                    # a live row wins a Claude session id two rows list (a name re-added after its retire)
                    if sid not in self.by_sid or (agent.live and not self.by_sid[sid].live):
                        self.by_sid[sid] = agent
        self._loose: dict[str, Agent] = {}

    def agent(self, sid: str) -> Agent:
        a = self.by_sid.get(sid)
        if a:
            return a
        a = self._loose.get(sid)
        if not a:
            a = self._loose[sid] = Agent(key="session:" + sid, name="session " + sid[:8], role="unknown", live=False, registered=False)
        return a


# ---------- the files ----------

@dataclass
class TFile:
    path: str
    sid: str            # the Claude session id the file belongs to (a subagent's: its parent's)
    sub: bool
    mtime: float
    size: int


def find_files(projects_dir: Path, since: float) -> tuple[list[TFile], int]:
    """The transcripts last written at or after `since` (epoch s), newest first, and how many there are in all. Only real files
    under the projects directory are looked at (no symlink is followed); a name that is no session id is left out."""
    out: list[TFile] = []
    total = 0
    root = str(projects_dir)
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames[:] = [d for d in dirnames if d != "tool-results"]
        rel = os.path.relpath(dirpath, root)
        parts = [] if rel == "." else rel.split(os.sep)
        if not parts:
            continue    # files straight in the projects directory are no project's
        for fn in filenames:
            if not fn.endswith(".jsonl"):
                continue
            if len(parts) == 1:
                sid, sub = fn[:-6], False
            elif len(parts) >= 3 and parts[2] == "subagents":
                sid, sub = parts[1], True
            else:
                continue
            if not SID_RE.match(sid):
                continue
            total += 1
            p = os.path.join(dirpath, fn)
            try:
                st = os.lstat(p)
            except OSError:
                continue
            if not (st.st_mode & 0o170000 == 0o100000) or st.st_mtime < since:
                continue
            out.append(TFile(p, sid, sub, st.st_mtime, st.st_size))
    out.sort(key=lambda f: -f.mtime)
    return out, total


def _iso_prefix(epoch: float) -> bytes:
    return datetime.fromtimestamp(epoch, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%S").encode()


def _line_ts(f, pos: int) -> tuple[bytes | None, int]:
    """The timestamp (to the second) of the first line that has one, starting at the first full line after `pos`, and the offset it
    starts at; (None, size) when there is none before the end."""
    f.seek(pos)
    if pos:
        f.readline()    # the rest of a line cut by the seek
    for _ in range(50):
        at = f.tell()
        line = f.readline()
        if not line:
            return None, at
        m = TS_RE.search(line)
        if m:
            return m.group(1), at
    return None, f.tell()


def start_offset(f, size: int, start_prefix: bytes) -> int:
    """Where to begin reading a transcript so that nothing before the range is read: a bisect on the lines' timestamps (a transcript is
    written in time order). Lands a little early rather than late: every line at or after the range's start is read."""
    if size < BISECT_MIN:
        return 0
    lo, hi = 0, size
    while hi - lo > BISECT_STOP:
        mid = (lo + hi) // 2
        ts, _at = _line_ts(f, mid)
        if ts is not None and ts < start_prefix:
            lo = mid
        else:
            hi = mid
    return lo


# ---------- one entry ----------

def _flat_input(inp: object) -> str:
    """A tool call's input as plain text: `key: "value", key: 3`, a string value as it is (not JSON-escaped), so a word matches
    what a person would read."""
    if not isinstance(inp, dict):
        return "" if inp is None else str(inp)
    parts = []
    for k, v in inp.items():
        parts.append(f'{k}: "{v}"' if isinstance(v, str) else f"{k}: {json.dumps(v, ensure_ascii=False)}")
    return ", ".join(parts)


def _tool_label(name: str) -> str:
    """`mcp__stackshot__update` -> `stackshot update`; any other tool as it is named."""
    if name.startswith("mcp__"):
        return " ".join(p for p in name.split("__")[1:] if p)
    return name


def _result_text(content: object) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b.get("text") or "" for b in content if isinstance(b, dict) and b.get("type") == "text")
    return ""


def _user_text(text: str) -> str:
    """What a person wrote, or "" for a notice (a system reminder, a hook's note, a command's echo, a task notification: tag-wrapped
    text the CLI made, which repeats on every turn and would drown the real matches)."""
    text = TR.PASTED_RE.sub("", TR.REMINDER_RE.sub("", text)).strip()
    m = TR.TAG_RE.match(text)
    if m and m.group(1) not in ("p", "b", "i"):
        return ""
    return text


def entries(d: dict, subagent: bool = False):
    """The searchable pieces of one transcript line: (kind, tool label, text), kind one of KINDS. A line that is no user or assistant
    line, is meta, or is one the chat never shows (TR.never_shown: a compaction summary, a sidechain line in a main transcript) has
    none; `subagent` says the line is from a subagent's own file, where sidechain lines are the point."""
    t = d.get("type")
    if t not in ("user", "assistant") or d.get("isMeta") or TR.never_shown(d, subagent):
        return
    msg = d.get("message")
    content = msg.get("content") if isinstance(msg, dict) else None
    if isinstance(content, str):
        text = _user_text(content) if t == "user" else content
        if text:
            yield "messages", "", text
        return
    if not isinstance(content, list):
        return
    for b in content:
        if not isinstance(b, dict):
            continue
        bt = b.get("type")
        if bt == "text" and isinstance(b.get("text"), str):
            text = _user_text(b["text"]) if t == "user" else b["text"]
            if text:
                yield "messages", "", text
        elif bt == "tool_use":
            yield "tools", _tool_label(str(b.get("name") or "tool")), _flat_input(b.get("input"))
        elif bt == "tool_result":
            text = _result_text(b.get("content"))
            if text:
                yield "output", "", text
        elif bt == "thinking" and isinstance(b.get("thinking"), str) and b["thinking"].strip():
            yield "thinking", "", b["thinking"]


def snippet(text: str, rx: re.Pattern) -> list[list]:
    """A short piece of `text` around its first match, white space collapsed, as parts [[text, 0 or 1]]: 1 is a word that matched (the
    page marks it). Parts, not offsets, so the page never has to agree with Python on what a character is; it builds text
    nodes from them, never HTML."""
    m = rx.search(text)
    pos = m.start() if m else 0
    a = max(0, pos - SNIPPET_BEFORE)
    window = text[a:pos + SNIPPET_AFTER]
    flat = " ".join(window.split())
    if a > 0:
        flat = "…" + flat
    if a + len(window) < len(text):
        flat += "…"
    parts: list[list] = []
    last = 0
    marks = 0
    for mm in rx.finditer(flat):
        if mm.end() == mm.start():
            continue
        if mm.start() > last:
            parts.append([flat[last:mm.start()], 0])
        parts.append([mm.group(0), 1])
        last = mm.end()
        marks += 1
        if marks >= MAX_MARKS:
            break
    if last < len(flat):
        parts.append([flat[last:], 0])
    return parts


# ---------- the search ----------

def _at_line_start(f, pos: int) -> bool:
    """Whether byte `pos` starts a line (the byte before it is a newline); leaves the file at `pos`."""
    f.seek(pos - 1)
    ok = f.read(1) == b"\n"
    f.seek(pos)
    return ok


# ---------- a subagent's entry opens its session's chat at the call that started it ----------

AGENT_TOOLS = ("Agent", "Task")       # the tool calls that start a subagent (Task was its earlier name)
SPAWN_GRACE_S = 5.0                   # the parent transcripts are read at most this long past the search's deadline
AGENT_FILE_RE = re.compile(r"^agent-([A-Za-z0-9_-]{1,64})\.jsonl$")


def subagent_id(path: str, line_agent_id: object = None) -> str | None:
    """A subagent transcript's agent id: its file name's (`agent-<id>.jsonl`), else the one its lines carry (`agentId`)."""
    m = AGENT_FILE_RE.match(os.path.basename(path))
    if m:
        return m.group(1)
    return line_agent_id if isinstance(line_agent_id, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,64}", line_agent_id) else None


def parent_transcript(sub_path: str) -> str:
    """`<project>/<session id>.jsonl` for a subagent's `<project>/<session id>/subagents/[...]agent-<id>.jsonl`."""
    p = Path(sub_path)
    while p.name != "subagents" and p.parent != p:
        p = p.parent
    return str(p.parent) + ".jsonl"


def spawn_points(parent: str, agent_ids: set[str], deadline: float | None = None, clock=time.monotonic) -> dict[str, tuple[int, str]]:
    """{agent id: (pos, uuid)} of the Agent/Task tool call in the session's transcript `parent` that started each subagent, in
    one pass over it. The link is the parent's own record of the subagent: the tool_result of that call carries
    `toolUseResult.agentId` (and a progress line `data.agentId` with `parentToolUseID`), whose tool_use_id names the call; the
    line holding the call gives its start (pos) and uuid. An agent whose call is not found is left out."""
    calls: dict[str, tuple[int, str]] = {}      # tool_use id -> (pos, uuid) of the line holding that Agent/Task call
    started: dict[str, str] = {}                # agent id -> tool_use id
    keys = [a.encode() for a in agent_ids]
    tool_keys = [f'"{t}"'.encode() for t in AGENT_TOOLS]
    try:
        f = open(parent, "rb")
    except OSError:
        return {}
    pos = 0
    n = 0
    with f:
        for line in f:
            at = pos
            pos += len(line)
            n += 1
            if deadline is not None and n % CHECK_EVERY == 0 and clock() > deadline:
                break
            is_call = b'"tool_use"' in line and any(k in line for k in tool_keys)
            is_link = b"agentId" in line and any(k in line for k in keys)
            if not (is_call or is_link):
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if not isinstance(d, dict):
                continue
            msg = d.get("message")
            content = msg.get("content") if isinstance(msg, dict) else None
            blocks = [b for b in content if isinstance(b, dict)] if isinstance(content, list) else []
            if is_call:
                for b in blocks:
                    if b.get("type") == "tool_use" and b.get("name") in AGENT_TOOLS and isinstance(b.get("id"), str):
                        calls.setdefault(b["id"], (at, str(d.get("uuid") or "")))
            if is_link:
                tur = d.get("toolUseResult")
                aid = tur.get("agentId") if isinstance(tur, dict) else None
                if aid in agent_ids:
                    for b in blocks:
                        if b.get("type") == "tool_result" and isinstance(b.get("tool_use_id"), str):
                            started.setdefault(aid, b["tool_use_id"])
                            break
                data = d.get("data")
                aid = data.get("agentId") if isinstance(data, dict) else None
                tuid = d.get("parentToolUseID") or d.get("parentToolUseId")
                if aid in agent_ids and isinstance(tuid, str):
                    started.setdefault(aid, tuid)
            if len(started) == len(agent_ids) and all(t in calls for t in started.values()):
                break
    return {a: calls[t] for a, t in started.items() if t in calls}


def place_subagents(results: list[dict], deadline: float | None = None, clock=time.monotonic) -> None:
    """Give each subagent result the place its session's chat opens at: `pos` and `target` of the Agent/Task call that started
    the subagent (spawn_points), one pass per session transcript; left at None/"" when it is not found. Drops the private
    `_file` and `_agentId` keys run() set."""
    want: dict[str, set[str]] = {}
    for h in results:
        if not h.get("sub"):
            continue
        aid = subagent_id(h.get("_file") or "", h.get("_agentId"))
        h["_aid"] = aid
        if aid:
            want.setdefault(parent_transcript(h["_file"]), set()).add(aid)
    found = {parent: spawn_points(parent, ids, deadline, clock) for parent, ids in want.items()}
    for h in results:
        if not h.get("sub"):
            continue
        place = found.get(parent_transcript(h["_file"]), {}).get(h["_aid"]) if h.get("_aid") else None
        if place:
            h["pos"], h["target"] = place
        for k in ("_file", "_agentId", "_aid"):
            h.pop(k, None)


@dataclass
class Params:
    words: list[str]
    since: float                       # epoch s
    until: float
    agents: set[str] = field(default_factory=lambda: {"front", "back", "sub", "unknown"})
    content: set[str] = field(default_factory=lambda: {"messages", "tools"})


def _epoch(ts: str | None) -> float | None:
    if not isinstance(ts, str):
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def run(params: Params, projects_dir: Path, registry_path: Path, roles: dict[str, dict],
        deadline_s: float = DEADLINE_S, cap: int = CAP, now: float | None = None, clock=time.monotonic) -> dict:
    """The answer to one search (see the module's docstring and GET /api/search for its shape)."""
    t0 = clock()
    deadline = t0 + deadline_s
    now_s = now if now is not None else time.time()
    directory = Directory(load_registry(registry_path), roles)
    files, total_files = find_files(projects_dir, params.since)
    pre = _prefilter_words(params.words)
    rx = re.compile("|".join(re.escape(w) for w in sorted(set(params.words), key=len, reverse=True)), re.I)
    start_prefix = _iso_prefix(params.since)
    agg: Counter = Counter()           # (category, kind) -> matches in range, whatever the switches say
    heap: list = []                    # the newest `cap` matches that pass the switches: (ts, seq, hit)
    seq = 0
    timed_out = False
    scanned = 0
    for tf in files:
        if clock() > deadline:
            timed_out = True
            break
        agent = directory.agent(tf.sid)
        cat = "sub" if tf.sub else agent.role
        try:
            f = open(tf.path, "rb")
        except OSError:
            continue
        scanned += 1
        with f:
            pos = start_offset(f, tf.size, start_prefix)
            f.seek(pos)
            if pos and not _at_line_start(f, pos):
                pos += len(f.readline())    # the rest of a line the bisect cut: no entry starts there
            n = 0
            for line in f:
                at = pos                    # this line's start: where its chat opens (GET transcript?around=)
                pos += len(line)
                n += 1
                if n % CHECK_EVERY == 0 and clock() > deadline:
                    timed_out = True
                    break
                if pre:
                    low = line.lower()
                    if not all(w in low for w in pre):
                        continue
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(d, dict):
                    continue
                ts = _epoch(d.get("timestamp"))
                if ts is None or ts < params.since or ts > params.until:
                    continue
                for kind, tool, text in entries(d, bool(tf.sub)):
                    low_t = text.lower()
                    if not all(w in low_t for w in params.words):
                        continue
                    agg[(cat, kind)] += 1
                    if cat not in params.agents or kind not in params.content:
                        continue
                    seq += 1
                    parts = snippet(text, rx)
                    hit = {"agent": agent.key, "name": agent.name, "role": agent.role, "sub": tf.sub, "kind": kind, "tool": tool,
                           "session": tf.sid, "uuid": d.get("uuid") or "", "ts": int(ts * 1000), "snippet": parts,
                           "pos": None if tf.sub else at, "target": "" if tf.sub else d.get("uuid") or ""}
                    if tf.sub:
                        hit["_file"], hit["_agentId"] = tf.path, d.get("agentId")
                    item = (ts, seq, hit)
                    if len(heap) < cap:
                        heapq.heappush(heap, item)
                    elif item[:2] > heap[0][:2]:
                        heapq.heapreplace(heap, item)
        if timed_out:
            break
    matches = sum(n for (c, k), n in agg.items() if c in params.agents and k in params.content)
    results = [h for _ts, _s, h in sorted(heap, reverse=True)]
    place_subagents(results, deadline + SPAWN_GRACE_S, clock)
    for h in results:
        z = SCH.zone_time(h["ts"] / 1000, now_s)
        h["when"] = z["when"] if z else ""
        h["at"] = z["text"] if z else ""
    return {
        "words": params.words,
        "from": int(params.since), "to": int(params.until),
        "fromText": (SCH.zone_time(params.since, now_s) or {}).get("text", ""),
        "toText": (SCH.zone_time(params.until, now_s) or {}).get("text", ""),
        "matches": matches, "shown": len(results), "cap": cap, "capped": matches > len(results),
        "timedOut": timed_out, "deadlineS": deadline_s,
        "files": {"scanned": scanned, "inRange": len(files), "all": total_files},
        "counts": {"agents": {c: sum(n for (cc, k), n in agg.items() if cc == c and k in params.content) for c in AGENT_CATS},
                   "content": {k: sum(n for (c, kk), n in agg.items() if kk == k and c in params.agents) for k in KINDS}},
        "elapsedMs": int((clock() - t0) * 1000),
        "results": results,
    }
