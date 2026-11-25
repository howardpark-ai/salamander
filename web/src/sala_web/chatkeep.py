"""The chat session's transcript, with the turns the owner did not start kept back (the server's half of the kept-back switch).

The chat session (SALA_CHAT_SESSION) is opened in sala's own view of a session: the same reads (GET /api/s/<pid>/transcript, the stream, the
sleeping session's transcript) and the same renderer. For that one session the server changes what those reads hold, by the rule in chatturns.py
(its module docstring is the rule: who started a turn is read from the line's own record of where its text came from, a line it does not
recognize counts as delivered):

  - a turn the owner started streams WHOLE, every line as sala shows it (tool calls, narration, results), as it arrives;
  - a turn something else started (another session, the board, sala, a background task, a plugin, a hook) is kept back: its lines are not sent. In
    their place goes ONE message of role "kept", at the place the turn started: {"uuid", "role": "kept", "ts", "blocks": [], "kept": {"src":
    {kind, name}, "what", "did", "open"}}. It is sent again with the same uuid when the turn's reply lands (the page replaces the line it has),
    so a line is never lost and never doubled;
  - a hidden turn whose reply opens with the owner's mark, `[for <owner>]`, is shown as that reply alone, the mark taken off, and its kept line
    is withdrawn: {"uuid", "role": "kept", "gone": true} (the mark is never displayed, in any turn);
  - the owner speaking into a turn something else started makes it his: its kept line stays (the delivered message is on record) with "open"
    false, and everything from there on is shown.

One state machine does all of it (Keeper), fed the transcript's lines in FILE order, so a page of history, an older page, a page around a Search
result and the live stream agree. A read starts from a point where no turn is open (just after a closing reply, found by looking back), and pages
hold whole turns, so a page never cuts a turn in two and the cursor of an older page is always the start of a turn. A line that belongs to no turn
(the file starts there, or the look back found no closing reply) is shown, never dropped.

The count of the switch is chatturns.kept_today (the same rule, over the turns of today); a test holds that it equals the kept lines.
"""

from __future__ import annotations

import json
from pathlib import Path

from . import chatturns as CT
from . import transcript as TR

KEPT = "kept"
SYNC_MAX = 8 << 20        # how far back a read looks for a point where no turn is open
WINDOW_FIRST = 1 << 20    # the first window of a read of the end of the file; doubled until the page is full
SCAN_MAX = 64 << 20       # a read gives up growing here (as read_tail does), the cursor says where to go on from
CHUNK = TR.CHUNK


def _kept_msg(uuid: str, ts: object, src: dict, what: str, did: str, open_: bool) -> dict:
    return {"uuid": uuid, "role": KEPT, "ts": ts, "blocks": [],
            "kept": {"src": {"kind": src.get("kind", "other"), "name": src.get("name", "")}, "what": what, "did": did, "open": open_}}


def _gone_msg(uuid: str) -> dict:
    return {"uuid": uuid, "role": KEPT, "ts": None, "blocks": [], "gone": True}


def _strip_mark(m: dict, mark) -> dict:
    """The owner's mark taken off the first text block of a shown reply (a reply that is only the mark keeps its text: nothing is dropped)."""
    for b in m.get("blocks", []):
        if b.get("kind") == "text":
            body = mark.sub("", b.get("text") or "", count=1).strip() if mark.match(b.get("text") or "") else ""
            if body:
                b["text"] = body
            break
    return m


class Keeper:
    """The state of the turn a transcript is in, and what each next line shows. feed(d, strict) -> the messages that line adds to the page, in
    order: display messages (as transcript.parse_line makes them) and kept lines (a role "kept" message, which replaces an earlier one with its
    uuid, or {"gone": true}, which withdraws it). `turn` counts the turns started so far (a page groups its messages by it)."""

    def __init__(self, session_id: str, owner: str):
        self.sid = session_id
        self.mark = CT._mark_re(owner)
        self.by: str | None = None      # who started the turn the transcript is in: "human", "other", or None before the first
        self.open = False
        self.replies = 0                # closing replies the turn has had (a hook's follow-up reopens it)
        self.kept: dict | None = None   # the kept line of the open hidden turn, while it stands
        self.owned = False              # a reply of the hidden turn showed: its kept line is withdrawn for good
        self.turn = 0

    # -- the parts ---------------------------------------------------------
    def _shown(self, d: dict) -> list[dict]:
        m = TR.parse_line(d, self.sid)
        if m is None:
            return []
        if m["role"] == "assistant":
            _strip_mark(m, self.mark)
        return [m]

    def _start(self, by: str) -> None:
        self.by, self.open, self.replies, self.kept, self.owned = by, True, 0, None, False
        self.turn += 1

    def _kept_copy(self) -> dict:
        k = self.kept
        return _kept_msg(k["uuid"], k["ts"], k["kept"]["src"], k["kept"]["what"], k["kept"]["did"], k["kept"]["open"])

    # -- one line ----------------------------------------------------------
    def feed(self, d: dict, strict: bool = False) -> list[dict]:
        if not isinstance(d, dict):
            return []
        if d.get("type") == "assistant":
            return self._assistant(d, strict)
        e = CT.classify_user(d)
        if e is None:     # a tool result, a command's own output, a sidechain or a summary: part of the turn it is in
            return [] if self.by == "other" else self._shown(d)
        if e["by"] == "human":
            out: list[dict] = []
            if self.open and self.by == "other":      # they spoke into a turn something else started: it is theirs now
                if self.kept is not None:
                    self.kept["kept"]["open"] = False
                    out.append(self._kept_copy())
                    self.kept = None
                self.by = "human"
            elif not (self.open and self.by == "human"):
                self._start("human")
            return out + self._shown(d)
        # delivered: it joins an open turn, goes on a closed one as a hook's follow-up, or starts a hidden turn
        if self.open:
            return [] if self.by == "other" else self._shown(d)
        if e.get("cont") and self.by is not None and self.replies:
            self.open = True
            return [] if self.by == "other" else self._shown(d)
        self._start("other")
        uuid = e.get("uuid") or f"kept-{e.get('ts') or self.turn}"
        src = {**e["src"], "text": e["text"], "images": e["images"]}
        self.kept = _kept_msg(uuid, d.get("timestamp"), e["src"], CT._phrase(src), "", True)
        return [self._kept_copy()]

    def _assistant(self, d: dict, strict: bool) -> list[dict]:
        r = CT.reply_of(d, strict)
        if r is None:                                  # a tool call, narration, an empty or unfinished line: part of the turn it is in
            return [] if self.by == "other" else self._shown(d)
        self.open = False
        self.replies += 1
        if self.by != "other":
            return self._shown(d)
        text = r["text"]
        if self.mark.match(text) and self.mark.sub("", text, count=1).strip():
            # a hidden turn that speaks to the owner: the reply alone, without the mark, and its kept line withdrawn
            m = TR.parse_line(d, self.sid)
            out: list[dict] = []
            if m is not None:
                m["blocks"] = [b for b in m["blocks"] if b.get("kind") == "text"]
                _strip_mark(m, self.mark)
                if m["blocks"]:
                    out.append(m)
            if self.kept is not None:
                out.append(_gone_msg(self.kept["uuid"]))
                self.kept = None
            self.owned = True
            return out
        if self.kept is None or self.owned:
            return []
        self.kept["kept"]["did"] = CT._last_line(self.mark.sub("", text, count=1))
        self.kept["kept"]["open"] = False
        return [self._kept_copy()]


# ── reading ──────────────────────────────────────────────────────────────────
def _decode(line: bytes) -> dict | None:
    if b'"user"' not in line and b'"assistant"' not in line and b'"queued_command"' not in line:
        return None
    try:
        d = json.loads(line)
    except ValueError:
        return None
    return d if isinstance(d, dict) and d.get("type") in ("user", "assistant", "attachment") else None


def _lines(path: Path, start: int, end: int):
    """(offset, bytes) of each complete line in [start, end), `start` a line's start and `end` a line's start or the end of the complete lines."""
    with path.open("rb") as f:
        pos, leftover, left_at = start, b"", start
        while pos < end:
            f.seek(pos)
            data = leftover + f.read(min(CHUNK, end - pos))
            pos = f.tell()
            parts = data.split(b"\n")
            leftover = parts.pop()
            off = left_at
            for p in parts:
                yield off, p
                off += len(p) + 1
            left_at = off


def _sync(path: Path, pos: int) -> int:
    """A line start at or before `pos` where no turn is open: just after the nearest closing reply that ends before `pos`. When the look back
    (SYNC_MAX bytes) finds none: the start of the first whole line it holds, or 0."""
    if pos <= 0:
        return 0
    lo = max(0, pos - SYNC_MAX)
    with path.open("rb") as f:
        f.seek(lo)
        parts = f.read(pos - lo).split(b"\n")
    offs, o = [], lo
    for p in parts:
        offs.append(o)
        o += len(p) + 1
    first = 1 if lo > 0 else 0          # the first piece is the tail of a line that began before `lo`
    for i in range(len(parts) - 2, first - 1, -1):      # the last piece is the head of the line `pos` cuts (empty when `pos` is a line's start)
        p = parts[i]
        if b'"assistant"' not in p:
            continue
        try:
            d = json.loads(p)
        except ValueError:
            continue
        if isinstance(d, dict) and CT.reply_of(d, True) is not None:
            return offs[i] + len(p) + 1
    return offs[first] if first < len(parts) - 1 else 0


def _fold(items: list[dict], by_kept: dict, off: int, turn: int, m: dict) -> None:
    """One message into a page's list: a kept line sent again takes the place of the first, a withdrawn one leaves (or, when it is not in the
    page, goes on as a message of its own, for the live stream)."""
    if m.get("role") != KEPT:
        items.append({"off": off, "turn": turn, "m": m})
        return
    u = m["uuid"]
    if m.get("gone"):
        it = by_kept.pop(u, None)
        if it is not None:
            it["m"] = None
        else:
            items.append({"off": off, "turn": turn, "m": m})
        return
    it = by_kept.get(u)
    if it is not None:
        it["m"] = m
        return
    it = {"off": off, "turn": turn, "m": m}
    by_kept[u] = it
    items.append(it)


def _scan(path: Path, sid: str, owner: str, start: int, end: int, strict: bool, keeper: Keeper | None = None) -> tuple[list[dict], Keeper]:
    kp = keeper or Keeper(sid, owner)
    items: list[dict] = []
    by_kept: dict = {}
    tstart: dict[int, int] = {}
    for off, line in _lines(path, start, end):
        d = _decode(line)
        if d is None:
            continue
        out = kp.feed(d, strict)
        tstart.setdefault(kp.turn, off)       # every message of a turn is at the turn's start: a page's cursor is the start of a turn, never the middle of one
        for m in out:
            _fold(items, by_kept, tstart[kp.turn], kp.turn, m)
    return [it for it in items if it["m"] is not None], kp


def _groups(items: list[dict]) -> list[list[dict]]:
    out: list[list[dict]] = []
    for it in items:
        if out and out[-1][0]["turn"] == it["turn"]:
            out[-1].append(it)
        else:
            out.append([it])
    return out


def read_back(path: Path, sid: str, owner: str, end: int, n: int, strict: bool = False,
              max_bytes: int = SCAN_MAX) -> tuple[list[dict], int, Keeper]:
    """The last `n` or more messages that end before byte `end` (a line's start), in whole turns, the cursor of the next older page (the start of
    the first turn taken; 0 when the file's start is in) and the Keeper in the state it reaches at `end`."""
    window = WINDOW_FIRST
    while True:
        want = max(0, end - window)
        b = _sync(path, want)
        items, kp = _scan(path, sid, owner, b, end, strict)
        groups = _groups(items)
        taken: list[list[dict]] = []
        count = 0
        for g in reversed(groups):
            taken.append(g)
            count += len(g)
            if count >= n:
                break
        taken.reverse()
        if count >= n or b == 0 or end - b >= max_bytes:
            msgs = [it["m"] for g in taken for it in g]
            if len(taken) == len(groups):
                cursor = 0 if b == 0 else b
            else:
                cursor = taken[0][0]["off"]
            return msgs, cursor, kp
        window *= 2


def read_tail_page(path: Path, sid: str, owner: str, n: int, strict: bool = False) -> tuple[list[dict], int, int, Keeper]:
    """(messages, cursor, end, keeper): the page the stream's reset and GET transcript send; `end` is where the live stream goes on from."""
    end = TR.complete_end(path)
    msgs, cursor, kp = read_back(path, sid, owner, end, n, strict)
    return msgs, cursor, end, kp


def read_before(path: Path, sid: str, owner: str, before: object, n: int, strict: bool = False) -> tuple[list[dict], int, bool]:
    """An older page: (messages, the new cursor, whether the file's start is in). A bad cursor raises TR.BadCursor."""
    end = TR.check_cursor(path, before)
    msgs, cursor, _ = read_back(path, sid, owner, end, n, strict)
    return msgs, cursor, cursor == 0


def read_fwd(path: Path, sid: str, owner: str, start: int, n: int, strict: bool = False,
             max_bytes: int = SCAN_MAX) -> tuple[list[dict], int, int]:
    """The `n` or more messages from byte `start` on (a turn's start), in whole turns: (messages, the cursor to go on from, the end of the
    complete lines). The cursor is the start of the first turn left out, or the end when the file's end is in."""
    end = TR.complete_end(path)
    window = WINDOW_FIRST
    while True:
        stop = min(end, start + window)
        b = _sync(path, start)
        items, _kp = _scan(path, sid, owner, b, stop, strict)
        items = [it for it in items if it["off"] >= start]
        groups = _groups(items)
        reached = stop >= end
        # a turn the window cuts is not whole: left for the next page unless it is the end of the file
        usable = groups if reached else groups[:-1]
        taken: list[list[dict]] = []
        count = 0
        for g in usable:
            taken.append(g)
            count += len(g)
            if count >= n:
                break
        if count >= n or reached or stop - start >= max_bytes:
            msgs = [it["m"] for g in taken for it in g]
            if len(taken) < len(groups):
                cursor = groups[len(taken)][0]["off"]
            else:
                cursor = end if reached else stop
            return msgs, cursor, end
        window *= 2


def read_after(path: Path, sid: str, owner: str, after: object, n: int, strict: bool = False) -> tuple[list[dict], int, bool]:
    start = TR.check_cursor(path, after)
    msgs, cursor, end = read_fwd(path, sid, owner, start, n, strict)
    return msgs, cursor, cursor >= end


def read_around(path: Path, sid: str, owner: str, at: object, n: int, strict: bool = False) -> dict:
    """A page around the line that starts at byte `at` (a Search result's pos), whole turns: the turn the line is in, older ones before it and
    newer ones after it, with the cursors and flags GET transcript?around= gives."""
    at = TR.check_cursor(path, at)
    b = _sync(path, at)
    # the start of the turn `at` is in: the last message at or before it (a line that shows nothing is in the turn the last message before it started)
    items, _kp = _scan(path, sid, owner, b, min(TR.complete_end(path), at + 1 + (1 << 20)), strict)
    first = [it["off"] for g in _groups(items) for it in g[:1] if it["off"] <= at]
    t = first[-1] if first else b
    half = max(1, n // 2)
    older, before, _ = read_back(path, sid, owner, t, half, strict)
    newer, after, end = read_fwd(path, sid, owner, t, max(1, n - len(older)), strict)
    return {"messages": older + newer, "before": before, "start": before == 0, "after": after, "end": after >= end}


def read_from(path: Path, keeper: Keeper, offset: int, strict: bool = False) -> tuple[list[dict], int]:
    """The stream's append: the messages the complete lines after `offset` add, given the state `keeper` is in, and the new offset."""
    end = TR.complete_end(path)
    if end <= offset:
        return [], offset
    items, _ = _scan(path, keeper.sid, "", offset, end, strict, keeper)
    return [it["m"] for it in items], end
