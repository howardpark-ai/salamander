"""The chat session's own thread (GET /api/chat/thread): what the owner wrote and what was answered to them, and nothing else. A pure selector over the
session's transcript: it writes nothing, stores nothing, and changes no other read of any session.

WHAT IS IN IT. Who wrote a line is chatturns.classify_user's decision alone (there is no second list here), so this thread and the chat session's own page
agree on what the owner wrote; the turn a transcript is in (who started it, the owner speaking into a delivered turn takes it over) is chatkeep.Keeper's,
with the two endings below; what a final reply is, chatturns.reply_of's (strict). Lines are read in file order. Three things show:

  1. what the owner wrote: every user or queued_command line classify_user calls the person's ("by": "human"). That is a line with origin human (not meta,
     not a compaction summary, not carrying sala's mark) whatever its promptSource (typed, queued, any other, or none), the queued_command attachment of a
     message typed while the session was busy, and a slash command or a `!` shell command typed in the pane. Each is drawn as the session's page draws it
     (transcript.parse_line: text and image blocks, a command's command block);
  2. the final replies of a turn the owner started: an assistant line reply_of calls final (a text block; a stop reason that is there and is not
     "tool_use", so a reply cut off at max_tokens counts; not a sidechain, not meta, not synthetic), its text blocks only. A leading [for <owner>] mark is
     taken off (a reply that is only the mark keeps its text). A hook that sends such a turn back for one more reply (a user line, meta, "Stop hook feedback:") gives two replies, and only the later shows: the
     reply or replies of the turn that stand directly before a refusal are left out once a reply follows it (several refusals in a row: the last reply
     only; no reply after it yet: the earlier one stays). Only the refusal line decides, never what the texts say;
  3. a reply of a turn something else started (another session, a background task, a hook or a plugin, the board, a line sala typed) only when it opens with
     that mark and says something after it; it shows without the mark. A reply that belongs to no turn the read knows of is held to the same rule.

Everything else yields nothing: tool calls and their results, thinking (the kind labelled narration too), text written on the way to a tool call, the
delivered messages themselves, hook and plugin lines, and (without `replies=1`) a command's own output. There are no kept lines.

THE REST OF A REPLY (`replies=1` on the route, which the page's layer sends; without it the answer holds the three above alone). These show too, the
first four only in a turn the owner started (a delivered turn's are kept back, as the chat session's own page keeps them):

  - the files of a SendUserFile call: an image as the file_image block transcript.parse_line makes, a file of any other kind as a block {"kind":
    "file_sent", "name", "caption"} (its name and no path; no route serves the file; the call's caption stands on its first file when none of its files
    is an image, whose block carries it otherwise). The call itself is not shown;
  - the questions of an AskUserQuestion call: a block {"kind": "question", "header", "question", "options": [{"label", "description", "preview"}]} each, the
    options in the order the session's dialog numbers them, with "multiSelect": true on one that takes several answers. It is read here and answered
    as every dialog is: on the page's question card (api/s/<pid>/dialog), from the composer (an option's number, or "esc") or the Terminal tab;
  - the answers such a call got, from its result's record (toolUseResult): a message on the owner's side, marked {"answer": true}, holding a block
    {"kind": "answer", "answers": [{"question", "answer"}]}. A call that was cancelled has none;
  - the line a request that ended in an API error leaves (an assistant line of model <synthetic> with isApiErrorMessage true): its text;
  - the interrupt line of the turn (below), on the owner's side of the thread and marked {"interrupt": true}: they did not write its words;
  - the output of the owner's `!` command or slash command: a message marked {"output": true}, as transcript.parse_line reads the line (a `!`
    command's output box, a slash command's folded notice). Output recorded as a system line is on no page, and not here.

None of them starts, ends or reopens a turn.

A TURN WITH NO REPLY. Three things Claude Code records end a turn without one, so that the next delivered line starts a turn of its own and its reply
needs the mark. A message the owner types afterwards is theirs as always, and an assistant line with no new message before it takes the ended turn up again.

  - an interrupt of the owner's turn: a user line with no origin, not meta, whose whole text is "[Request interrupted by user]" or "[Request interrupted
    by user for tool use]";
  - a command that only ran locally: the owner's slash command followed, with no assistant line and no other turn line between, by its local output (a
    user line with no origin, or a system line of subtype local_command, that opens with <local-command-stdout> or <local-command-stderr>). Such a command
    leaves the turn as it found it: no turn open stays so; a turn of theirs that is still working stays theirs; a delivered one that was open stays
    delivered. The caveat line Claude Code writes ahead of it (meta, no origin, <local-command-caveat>) opens nothing.
  - a `!` command that found no turn open, at its output (chatkeep.Keeper). One typed into an open turn takes it over, as any message of theirs does.

The transcript does not say that a turn ended when there is no such line (an interrupt that wrote none, a command with neither output nor reply, a turn an
API error or a restart cut off): it stays open, and the next delivered message's reply counts as that turn's.

PAGES hold whole turns and every cursor is a line's start, as in chatkeep. A read starts at a line that starts a turn whatever came before it (the first user
or queued line after a closing reply that is neither a hook's follow-up, which belongs to the turn before, nor a command's caveat), so a page, an older page
and the live appends (read_from) give the same thread. The end of the file is read in segments, newest first, none read twice, and a page that holds a message
stops growing at PAGE_BYTES: a large transcript is never read whole for one page, so a page may hold fewer messages than asked while `start` is false."""

from __future__ import annotations

import json
import re
from pathlib import Path

from . import chatkeep as CK
from . import chatturns as CT
from . import sentimages as SI
from . import transcript as TR

WINDOW_FIRST = 1 << 20    # bytes of the first segment of a read; each further one is twice as long
PAGE_BYTES = 4 << 20      # a page that holds a message stops growing once it has read this far back or on
SCAN_MAX = 64 << 20       # how far a read goes with nothing to show, and how far back it looks for a turn's start (the other reads' limit)
STEP = 256 << 10          # one read of that look back
CACHE_MAX = 8
_NOT_WRITTEN = ("tool_use", "tool_result", "thinking")
# Claude Code's own records (the whole text of an interrupt; how a command, the notice ahead of it and its local output begin)
_INTERRUPT = re.compile(r"\[Request interrupted by user(?: for tool use)?\]")
_COMMAND = ("<command-name>", "<command-message>")
_CAVEAT = "<local-command-caveat>"
_OUTPUT = ("<local-command-stdout>", "<local-command-stderr>")


def _words_only(d: dict) -> dict:
    """An assistant line with every content block that is not text replaced by an empty one, so that a block keeps its index (an image's address is built
    from it). A thinking block labelled narration is one parse_line would draw as text: it is not part of the reply here."""
    msg = d.get("message")
    content = msg.get("content") if isinstance(msg, dict) else None
    if not isinstance(content, list):
        return d
    blocks = [b if isinstance(b, dict) and b.get("type") == "text" else {"type": "omitted"} for b in content]
    return {**d, "message": {**msg, "content": blocks}}


def _raw(d: dict) -> str:
    """A user line's own text, cleaned as classify_user cleans it ("" for a tool result: it holds no text block)."""
    msg = d.get("message")
    return CT._clean(CT._texts(msg.get("content") if isinstance(msg, dict) else None)[0])


def _from_cli(d: dict) -> str | None:
    """What Claude Code itself recorded about an interrupt or a command it ran locally: "interrupt", "output" (the command's local output), "caveat"
    (the notice it writes ahead of a local command), or None for any other line. Only a line with no origin (nobody sent it) is one."""
    if d.get("type") == "system":
        content = d.get("content")
        local = d.get("subtype") == "local_command" and isinstance(content, str) and content.lstrip().startswith(_OUTPUT)
        return "output" if local else None
    if d.get("type") != "user" or d.get("isSidechain") or d.get("origin") is not None:
        return None
    text = _raw(d)
    if d.get("isMeta"):
        return "caveat" if text.startswith(_CAVEAT) else None
    if _INTERRUPT.fullmatch(text):
        return "interrupt"
    return "output" if text.startswith(_OUTPUT) else None


def _refusal(d: dict) -> bool:
    """Whether a line is Claude Code's record of a Stop hook refusing a reply: a user line, meta, not a sidechain, whose text is "Stop hook feedback:" and what
    the hook said (the same line chatturns takes for a hook's follow-up). The summary system line and the blocking-error attachment beside it say it a second time."""
    return (d.get("type") == "user" and d.get("isMeta") is True and not d.get("isSidechain") and _raw(d).startswith(CT._CONTINUATION_TEXT))


def _questions(content: object) -> list[dict]:
    """A block of kind "question" for each question of the AskUserQuestion calls among a message's content blocks."""
    def words(d: dict, key: str) -> str:
        return d[key] if isinstance(d.get(key), str) else ""

    out = []
    for call in content if isinstance(content, list) else []:
        if not isinstance(call, dict) or call.get("type") != "tool_use" or call.get("name") != "AskUserQuestion":
            continue
        asked = call["input"].get("questions") if isinstance(call.get("input"), dict) else None
        for q in asked if isinstance(asked, list) else []:
            if not isinstance(q, dict) or not words(q, "question"):
                continue
            options = q.get("options") if isinstance(q.get("options"), list) else []
            out.append({"kind": "question", "header": words(q, "header"), "question": words(q, "question"),
                        "options": [{k: words(o, k) for k in ("label", "description", "preview")} for o in options if isinstance(o, dict)],
                        **({"multiSelect": True} if q.get("multiSelect") is True else {})})
    return out


def _answers(result: object) -> list[dict]:
    """The block of kind "answer" for a tool result's record that holds an AskUserQuestion call's answers, in the order the questions were asked."""
    if not isinstance(result, dict) or not isinstance(result.get("questions"), list) or not isinstance(result.get("answers"), dict):
        return []
    pairs = []
    for q in result["questions"]:
        asked = q.get("question") if isinstance(q, dict) else None
        answer = result["answers"].get(asked) if isinstance(asked, str) else None
        if isinstance(answer, list):
            answer = ", ".join(a for a in answer if isinstance(a, str))
        if isinstance(answer, str) and answer.strip():
            pairs.append({"question": asked, "answer": answer})
    return [{"kind": "answer", "answers": pairs}] if pairs else []


def _files(content: object) -> list[dict]:
    """A block of kind "file_sent" for each file that is no image among those the SendUserFile calls of a message's content blocks sent (an image has
    transcript.parse_line's own block). A call's caption stands on its first file when none of its files is an image."""
    out = []
    for call in content if isinstance(content, list) else []:
        if not isinstance(call, dict) or call.get("type") != "tool_use" or call.get("name") != SI.TOOL_NAME:
            continue
        inp = call["input"] if isinstance(call.get("input"), dict) else {}
        paths = [raw for raw in map(SI.raw_path, inp["files"] if isinstance(inp.get("files"), list) else []) if raw]
        others = [raw for raw in paths if not SI.is_image_name(raw)]
        caption = inp.get("caption") if len(others) == len(paths) else None
        for k, raw in enumerate(others):
            out.append({"kind": "file_sent", "name": raw.replace("\\", "/").rstrip("/").rsplit("/", 1)[-1][:120],
                        "caption": " ".join(caption.split())[:300] if isinstance(caption, str) and k == 0 else ""})
    return out


class Selector(CK.Keeper):
    """chatkeep.Keeper's turn state with only the thread's messages let through, and with the two ends of a turn that have no reply (an interrupt, a
    command that only ran locally). feed(line) -> the messages that line adds (at most one), shaped as transcript.parse_line makes them; `open` says
    whether a turn is open after the lines fed so far. `rest`: the rest of a reply is let through too (module docstring)."""

    def __init__(self, session_id: str, owner: str, rest: bool = False):
        super().__init__(session_id, owner)
        self.rest = rest
        self.before: tuple | None = None    # (open, by) as the owner's slash command found them, while its local output may still follow
        self.since: list[str] = []          # uuids of the replies shown since the last Stop hook refusal (or the turn's start)
        self.held: list[str] = []           # those a Stop hook refusal came right after: hidden as soon as a later reply shows
        self.hidden: set[str] = set()       # uuids of the replies a later reply took the place of
        self._turn = self.turn

    def feed(self, d: dict, strict: bool = True) -> list[dict]:
        """`strict` is Keeper.feed's signature: here a reply always needs a stop reason, so a read never depends on whether the session is working."""
        if not isinstance(d, dict):
            return []
        if self.turn != self._turn:      # a reply never takes the place of one of another turn
            self._turn, self.since, self.held = self.turn, [], []
        if _refusal(d):
            self.held, self.since = self.held + self.since, []
        out = self._feed(d)
        if self.turn != self._turn:
            self._turn, self.since, self.held = self.turn, [], []
        if any(m["role"] == "user" and not (m.get("answer") or m.get("output") or m.get("interrupt")) for m in out):
            self.since, self.held = [], []    # the owner wrote: what came before is answered
        return out

    def _feed(self, d: dict) -> list[dict]:
        if d.get("type") == "assistant":
            return self._reply(d)
        cli = _from_cli(d)
        if cli == "caveat":              # part of the command that follows it, not a message that opens a turn
            return []
        if self._bang_end(d):            # the output of the owner's `!` command
            return self._output(d)
        if cli == "output":
            if self.before is None:      # not the output of a command of the owner's
                return []
            was_open, by = self.before   # the owner's command ran locally: the turn is as the command found it
            self.before = None
            if was_open:
                self.by = by
            else:
                self._stop()
            return self._output(d)
        if cli == "interrupt" and self.open and self.by == "human":
            self.before = None
            self._stop()
            m = TR.parse_line(d, self.sid) if self.rest else None
            return [{**m, "interrupt": True}] if m else []
        e = CT.classify_user(d)
        if e is None:                    # no turn starts or changes at it
            return self._answered(d)
        found = (self.open, self.by)
        self.before = None
        out = super().feed(d, True)
        if e["by"] != "human":
            return []
        if d.get("type") == "user" and _raw(d).startswith(_COMMAND):
            self.before = found
        picked = []
        for m in out:
            if m["role"] != "user":      # a kept line the owner's message closed
                continue
            blocks = [b for b in m["blocks"] if b["kind"] not in _NOT_WRITTEN]
            if blocks:
                picked.append({**m, "blocks": blocks})
        return picked

    def _output(self, d: dict) -> list[dict]:
        """The output of a command of the owner's, marked as output (they did not write its words)."""
        m = TR.parse_line(d, self.sid) if self.rest else None      # None for a system line
        return [{**m, "output": True}] if m else []

    def _answered(self, d: dict) -> list[dict]:
        """The answers to a question asked in the owner's turn: a message on their side, marked as an answer."""
        if not self.rest or self.by != "human" or d.get("type") != "user" or d.get("isMeta") or TR.never_shown(d):
            return []
        blocks = _answers(d.get("toolUseResult"))
        return [{"uuid": d.get("uuid") or "", "role": "user", "ts": d.get("timestamp"), "blocks": blocks, "answer": True}] if blocks else []

    def _reply(self, d: dict) -> list[dict]:
        if CT.from_model(d):             # the session's model is at work
            self.before = None
            self._resume(d)
        r = CT.reply_of(d, True)
        if r is None:                    # narration, a tool call, thinking, an API error: the turn goes on
            return self._rest_of(d) if self.rest else []
        unplaced = self.by is None
        out = super().feed(_words_only(d), True)
        if unplaced and not (self.mark.match(r["text"]) and self.mark.sub("", r["text"], count=1).strip()):
            return []
        replies = [m for m in out if m["role"] == "assistant"]
        if replies:                      # a reply after a refusal takes the place of the replies before it
            self.hidden.update(self.held)
            self.held = []
            self.since += [m["uuid"] for m in replies if m["uuid"]]
        return replies

    def _rest_of(self, d: dict) -> list[dict]:
        """What a line that is no final reply still shows of a reply to the owner: the files and questions of its calls, or an API error's words."""
        m = TR.parse_line(d, self.sid) if self.by == "human" else None      # None for a sidechain or a meta line too
        if m is None:
            return []
        msg = d["message"]
        if msg.get("model") == "<synthetic>":
            blocks = [b for b in m["blocks"] if b["kind"] == "text"] if d.get("isApiErrorMessage") is True else []
        else:
            blocks = [b for b in m["blocks"] if b["kind"] == "file_image"] + _files(msg.get("content")) + _questions(msg.get("content"))
        return [{**m, "blocks": blocks}] if blocks else []


# ── reading ──────────────────────────────────────────────────────────────────
def _lines_back(path: Path, pos: int, limit: int):
    """(offset, bytes) of each complete line that ends at or before byte `pos`, nearest first, read STEP bytes at a time, at most `limit` bytes back."""
    lo = max(0, pos - limit)
    with path.open("rb") as f:
        at, head, cut = pos, b"", True
        while at > lo:
            start = max(lo, at - STEP)
            f.seek(start)
            parts = (f.read(at - start) + head).split(b"\n")
            at = start
            if cut:                  # what follows the last newline before `pos`: nothing, or the head of a line `pos` cuts
                parts.pop()
                if not parts:
                    continue
                cut = False
            offs, o = [], at
            for p in parts:
                offs.append(o)
                o += len(p) + 1
            head = parts[0]          # may have begun before `at`: finished by the next read
            for i in range(len(parts) - 1, 0, -1):
                yield offs[i], parts[i]
        if at == 0 and not cut:
            yield 0, head


def _turn_start(path: Path, pos: int) -> int:
    """The start of the nearest turn that begins before byte `pos`, where a read can start knowing nothing of what came before: the first user or queued
    line after a closing reply, unless it is a hook's follow-up (which belongs to the turn before). 0 when the look back reaches the file's start; when it
    gives up after SCAN_MAX bytes, the earliest line it read."""
    found = None
    earliest = pos
    for off, line in _lines_back(path, pos, SCAN_MAX):
        earliest = off
        d = CK._decode(line)
        if d is None:
            continue
        if d.get("type") == "assistant":
            if found is not None and CT.reply_of(d, True) is not None:
                return found
            continue
        if _from_cli(d) == "caveat":     # the selector passes over it, so no read starts at it
            continue
        e = CT.classify_user(d)
        if e is not None:
            found = None if e.get("cont") else off
    return 0 if pos <= SCAN_MAX else earliest


def _decode(line: bytes) -> dict | None:
    """A line the selector reads: chatkeep's (user, assistant, queued_command), and a command's local output that was recorded as a system line."""
    if b'"local_command"' in line:
        try:
            d = json.loads(line)
        except ValueError:
            return None
        if isinstance(d, dict) and d.get("type") == "system":
            return d if d.get("subtype") == "local_command" else None
    return CK._decode(line)


def _items(path: Path, start: int, end: int, sel: Selector) -> list[dict]:
    """The messages of the lines in [start, end) fed to `sel`, each with its turn's number and the start of that turn (chatkeep._scan's shape)."""
    items: list[dict] = []
    starts: dict[int, int] = {}
    for off, line in CK._lines(path, start, end):
        d = _decode(line)
        if d is None:
            continue
        out = sel.feed(TR.as_delivered(path, off, d))
        if d.get("type") != "system":     # a system line adds no message and starts no turn
            starts.setdefault(sel.turn, off)
        items.extend({"off": starts[sel.turn], "turn": sel.turn, "m": m} for m in out)
    return [it for it in items if it["m"]["uuid"] not in sel.hidden] if sel.hidden else items


def _scan(path: Path, sid: str, owner: str, start: int, end: int, rest: bool = False) -> tuple[list[list[dict]], Selector]:
    """(the messages of the lines in [start, end), grouped by turn as chatkeep groups them, the selector in the state it reaches)."""
    sel = Selector(sid, owner, rest)
    return CK._groups(_items(path, start, end, sel)), sel


def read_back(path: Path, sid: str, owner: str, end: int, n: int, rest: bool = False) -> tuple[list[dict], int, Selector]:
    """The last `n` or more messages that end before byte `end` (a line's start), in whole turns; the cursor of the next older page (0 when the file's start
    is in); and the selector in the state it reaches at `end`. Each segment starts at a turn's start, so an earlier one needs nothing of a later one."""
    groups: list[list[dict]] = []
    state = None
    stop, window = end, WINDOW_FIRST
    while True:
        start = _turn_start(path, max(0, stop - window))
        found, sel = _scan(path, sid, owner, start, stop, rest)
        if state is None:
            state = sel
        groups[:0] = found
        stop = start
        count = sum(len(g) for g in groups)
        if count >= n or start == 0 or (count and end - start >= PAGE_BYTES) or end - start >= SCAN_MAX:
            break
        window *= 2
    taken: list[list[dict]] = []
    count = 0
    for g in reversed(groups):
        taken.append(g)
        count += len(g)
        if count >= n:
            break
    taken.reverse()
    cursor = stop if len(taken) == len(groups) else taken[0][0]["off"]
    return [it["m"] for g in taken for it in g], cursor, state


def read_tail_page(path: Path, sid: str, owner: str, n: int, rest: bool = False) -> tuple[list[dict], int, int, Selector]:
    """(messages, cursor, end, selector): the newest page; `end` and the selector are where read_from goes on from."""
    end = TR.complete_end(path)
    msgs, cursor, sel = read_back(path, sid, owner, end, n, rest)
    return msgs, cursor, end, sel


def read_before(path: Path, sid: str, owner: str, before: object, n: int, rest: bool = False) -> tuple[list[dict], int, bool]:
    """An older page: (messages, the new cursor, whether the file's start is in). A bad cursor raises TR.BadCursor."""
    msgs, cursor, _ = read_back(path, sid, owner, TR.check_cursor(path, before), n, rest)
    return msgs, cursor, cursor == 0


def read_fwd(path: Path, sid: str, owner: str, start: int, n: int, rest: bool = False) -> tuple[list[dict], int, int]:
    """The `n` or more messages of the turns from byte `start` (a turn's start) on, whole turns: (messages, the cursor to go on from, the end of the
    complete lines)."""
    end = TR.complete_end(path)
    base = _turn_start(path, start)
    window = WINDOW_FIRST
    while True:
        stop = min(end, start + window)
        reached = stop >= end
        found, _ = _scan(path, sid, owner, base, stop, rest)
        whole = end if reached else _turn_start(path, stop)      # every turn that starts before this byte was read to its end
        groups = [g for g in found if g[0]["off"] >= start]
        taken: list[list[dict]] = []
        count = 0
        for g in groups:
            if g[0]["off"] >= whole or count >= n:
                break
            taken.append(g)
            count += len(g)
        if reached or count >= n or (count and stop - start >= PAGE_BYTES) or (whole > start and stop - start >= SCAN_MAX):
            cursor = groups[len(taken)][0]["off"] if len(taken) < len(groups) else max(whole, start)
            return [it["m"] for g in taken for it in g], cursor, end
        window *= 2


def read_after(path: Path, sid: str, owner: str, after: object, n: int, rest: bool = False) -> tuple[list[dict], int, bool]:
    """A newer page: (messages, the new cursor, whether the end of the file is in). A bad cursor raises TR.BadCursor."""
    msgs, cursor, end = read_fwd(path, sid, owner, TR.check_cursor(path, after), n, rest)
    return msgs, cursor, cursor >= end


def read_around(path: Path, sid: str, owner: str, at: object, n: int, rest: bool = False) -> dict:
    """A page around the line that starts at byte `at`, whole turns: the turn the line is in and newer ones, older ones before it, with the cursors and
    flags GET transcript?around= gives. A bad cursor raises TR.BadCursor."""
    at = TR.check_cursor(path, at)
    with path.open("rb") as f:
        f.seek(at)
        f.readline()
        past = min(f.tell(), TR.complete_end(path))
    turn = _turn_start(path, past)
    older, before, _ = read_back(path, sid, owner, turn, max(1, n // 2), rest)
    newer, after, end = read_fwd(path, sid, owner, turn, max(1, n - len(older)), rest)
    return {"messages": older + newer, "before": before, "start": before == 0, "after": after, "end": after >= end}


def read_from(path: Path, selector: Selector, offset: int) -> tuple[list[dict], int]:
    """The messages the complete lines after `offset` add, given the state `selector` is in, and the new offset."""
    end = TR.complete_end(path)
    if end <= offset:
        return [], offset
    return [it["m"] for it in _items(path, offset, end, selector)], end


def is_open(path: Path, sid: str, owner: str) -> bool:
    """Whether a turn is open at the end of the transcript (its last turn alone is read)."""
    end = TR.complete_end(path)
    return _scan(path, sid, owner, _turn_start(path, end), end)[1].open


def tail(path: Path, sid: str, owner: str, n: int, cache: dict, rest: bool = False) -> tuple[list[dict], int, int, bool]:
    """read_tail_page as the route asks for it: (messages, cursor, end, open), kept in `cache` (a dict the caller keeps) while the file's size and time are
    unchanged, so a poll of a quiet session costs a stat. The messages are the cache's own: a caller copies one before it adds to it."""
    st = path.stat()
    key = (str(path), n, rest)
    stamp = (st.st_size, st.st_mtime_ns, sid, owner)
    hit = cache.get(key)
    if hit is None or hit[0] != stamp:
        msgs, cursor, end, sel = read_tail_page(path, sid, owner, n, rest)
        if len(cache) >= CACHE_MAX:
            cache.clear()
        cache[key] = hit = (stamp, (msgs, cursor, end, sel.open))
    return hit[1]


def answer(*, name: str, sess, projects_dir: Path, owner: str, n: int, before, around, after, host: str, mockups_dir: Path, cache: dict,
           rest: bool = False) -> dict:
    """The answer of GET /api/chat/thread for the configured chat session `name` (`sess`: its Session, live or sleeping, or None when sala has no such
    session); at most one of `before`, `around` and `after` is given, and a bad one raises TR.BadCursor. {"session", "messages", the paging keys the
    transcript route gives for that kind of read, "busy": a turn is open and the session is working, "cards": {uuid: the link cards of that reply}}; each
    reply that has cards also carries them as `cards`, as the session's page draws them. `rest`: the route's `replies=1` (module docstring)."""
    path = TR.transcript_path(projects_dir, sess.cwd, sess.session_id) if sess is not None else None
    if path is None:
        return {"session": name, "messages": [], "offset": 0, "before": 0, "start": True, "busy": False, "cards": {}}
    sid = sess.session_id
    working = sess.status in ("busy", "waiting")
    if before is None and around is None and after is None:
        msgs, cursor, end, open_ = tail(path, sid, owner, n, cache, rest)
        page = {"messages": msgs, "offset": end, "before": cursor, "start": cursor == 0}
    else:
        if around is not None:
            page = read_around(path, sid, owner, around, n, rest)
        elif after is not None:
            msgs, cursor, at_end = read_after(path, sid, owner, after, n, rest)
            page = {"messages": msgs, "after": cursor, "end": at_end}
        else:
            msgs, cursor, at_start = read_before(path, sid, owner, before, n, rest)
            page = {"messages": msgs, "before": cursor, "start": at_start}
        open_ = working and is_open(path, sid, owner)
    msgs = CK.with_cards([dict(m) for m in page["messages"]], host, mockups_dir)
    return {"session": name, **page, "messages": msgs, "busy": working and open_,
            "cards": {m["uuid"]: m["cards"] for m in msgs if "cards" in m}}
