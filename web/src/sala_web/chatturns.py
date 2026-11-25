"""The chat page's turns (GET /chat, GET /api/chat): what the person typed to one session, the final reply of each turn they started, and
the one-line record of every turn something else started.

WHAT SHOWS. Two kinds of turn, read from the session's transcript (~/.claude/projects/<slug>/<sessionId>.jsonl):

  1. A turn the person started: what they typed (a bubble) and the FINAL reply of the turn (a message). No tool call, no narration, no
     text a reply wrote on its way to a tool call.
  2. A turn something else started (another session, the board, sala, a background task, a plugin) whose final reply opens with the
     owner's mark, `[for <owner>]` (the mark is taken off; the message carries the label "<name>, on his own"). Every other such turn is
     HIDDEN, and each hidden turn is one quiet line under the "kept back" switch (never dropped: the count and the line are the check
     against silence).

TYPED VERSUS DELIVERED. This rule was established from real transcripts (a count over the recent transcripts of one machine, read-only;
the shapes below are what they hold) and is the only thing that decides who started a turn. It reads the line's own record of where the
text came from, never its words:

  typed (the person)
    - a `user` line with origin.kind == "human" (not isMeta, not isCompactSummary), whatever its promptSource: "typed" (the composer's paste
      and the pane's keys alike) or "queued" (typed while the session was busy and run later);
    - an `attachment` line of type queued_command with origin.kind == "human" (typed while the session was busy: its text is the
      attachment's `prompt`; its own timestamp is when the session took it up, which is why lines are read in FILE order and never sorted
      by time);
    - a `user` line with no origin that is a slash command the person typed in the pane (`<command-name>` / `<command-message>` text, not
      isMeta). Its `<local-command-stdout>` / `<local-command-caveat>` lines are the command's output, not a turn start.
  delivered (something else)
    - origin.kind == "peer" (isMeta): text "Another Claude session sent a message:" and then a header: `from: NAME`, `[stackshot message]
      from NAME ...`, `[stackshot] ...`, `[anchor] ...`, `[sala op|note|notice ...] ...`, or a `<cross-session-message ...>` tag. The same
      three forms arrive as a queued_command attachment with origin peer;
    - origin.kind == "task-notification" (`<task-notification>` text), as a user line or a queued_command attachment;
    - origin.kind == "plugin" (a hook's or plugin's message), and the meta lines with no origin at all (skill text, hook feedback, an
      image's source line, `/exit`'s output);
    - a user line with no `origin` key whose promptSource is "sdk" (a prompt a program sent in).
  skipped (neither: no turn, no line anywhere)
    - tool results, sidechain (subagent) lines, compaction summaries (isCompactSummary / isVisibleInTranscriptOnly, whatever their
      turnOrigin says), and every line that is not a user, assistant or queued_command line.
  A line this rule does not recognize at all (an unknown origin kind) counts as DELIVERED, so it is kept back and counted, never lost.

TURNS. Lines are read in file order. The typed text starts a turn, or joins the open one (the person typing while the session works; a
turn that something else started and that is still open becomes the person's: they spoke into it). A delivered line starts a hidden turn
only when no turn is open, and joins the open one otherwise. A turn closes at a reply: an assistant line with a text block whose
stop_reason is neither "tool_use" (the text was written on the way to a tool call: narration) nor missing while the session works
(unfinished). A hook's follow-up after a closed turn (Stop-hook feedback, a plugin's message) belongs to that turn, so a person's turn that
a hook sends back for one more reply shows both replies. The "final reply" of a hidden turn is its last one.

Not here: the check on turns nobody marked (a later build), and anything that changes how a session is routed. A doubtful line goes to the
kept-back list, never nowhere.
"""

from __future__ import annotations

import json
import re
from datetime import datetime, timezone
from pathlib import Path

from . import transcript as TR

WINDOW_FIRST = 2 << 20          # the first read from the end of the transcript, doubled until it reaches back far enough or hits the cap
WINDOW_CAP = 24 << 20
TURNS_WANTED = 150              # a read stops growing once it holds this many turns and reaches back to the start of today
TEXT_MAX = 20_000
PHRASE_MAX = 90                 # a kept-back line's "what it was"
DID_MAX = 110                   # and its "what the session did"

# the head of a delivered message, after "Another Claude session sent a message:"
_HEAD_FROM = re.compile(r"from: *([A-Za-z0-9][A-Za-z0-9._-]*)")
_HEAD_MSG = re.compile(r"\[stackshot message\] from ([A-Za-z0-9][A-Za-z0-9._-]*)")
_HEAD_TAG = re.compile(r"^\[([A-Za-z]+)(?: [^\]\n]*)?\]")
_TAG_FROM_NAME = re.compile(r'<cross-session-message\b[^>]*\bfrom-name="([^"\n]*)"')
_TASK_SUMMARY = re.compile(r"<summary>(.*?)</summary>", re.S)
_FOOTER_START = re.compile(r"^(?:Write-up|Board|Page)s?\b\s*[:\[]|^Board\s+(?:board|[a-z]\d)", re.I)
_MD_LINK = re.compile(r"\[([^\]\n]*)\]\([^)\n]*\)")
_CONTINUATION_TEXT = ("Stop hook feedback:",)


def _ms(ts: object) -> int | None:
    if not isinstance(ts, str):
        return None
    try:
        return int(datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp() * 1000)
    except ValueError:
        return None


def _texts(content: object) -> tuple[str, int]:
    """(the text blocks of a message's content joined, how many image blocks it holds)."""
    if isinstance(content, str):
        return content, 0
    if not isinstance(content, list):
        return "", 0
    parts, images = [], 0
    for b in content:
        if not isinstance(b, dict):
            continue
        if b.get("type") == "text" and isinstance(b.get("text"), str):
            parts.append(b["text"])
        elif b.get("type") == "image":
            images += 1
    return "\n".join(parts), images


def _clean(text: str) -> str:
    return TR.PASTED_RE.sub("", TR.REMINDER_RE.sub("", text)).strip()


def _clip(s: str, n: int) -> str:
    s = " ".join(s.split())
    return s if len(s) <= n else s[: n - 1].rstrip() + "…"


def _is_tool_result(d: dict, content: object) -> bool:
    if "toolUseResult" in d or "sourceToolAssistantUUID" in d:
        return True
    return isinstance(content, list) and bool(content) and isinstance(content[0], dict) and content[0].get("type") == "tool_result"


def classify_user(d: dict) -> dict | None:
    """One `user` or queued_command line -> {"by": "human" | "other", "text", "images", "src": {...}, "cont": bool, "ts", "uuid"}, or None for a
    line that is no turn start (a tool result, a sidechain, a compaction stub, a command's own output). "src" (delivered lines) says where
    it came from: {"kind": "sala" | "board" | "session" | "other" | "task" | "system", "name": str}. "cont": a hook's follow-up, which belongs
    to the turn before it. This is the rule of the module docstring."""
    t = d.get("type")
    if t == "attachment":
        a = d.get("attachment")
        if not isinstance(a, dict) or a.get("type") != "queued_command":
            return None
        content, origin, meta, uuid = a.get("prompt"), a.get("origin"), bool(a.get("isMeta")), d.get("uuid") or ""
        prompt_source = None
        if origin is None and a.get("commandMode") == "task-notification":
            origin = {"kind": "task-notification"}
    elif t == "user":
        if d.get("isSidechain") or d.get("isCompactSummary") or d.get("isVisibleInTranscriptOnly"):
            return None
        msg = d.get("message")
        content = msg.get("content") if isinstance(msg, dict) else None
        if _is_tool_result(d, content):
            return None
        origin, meta, uuid, prompt_source = d.get("origin"), bool(d.get("isMeta")), d.get("uuid") or "", d.get("promptSource")
    else:
        return None
    if d.get("isSidechain"):
        return None
    text, images = _texts(content)
    text = _clean(text)
    ts = _ms(d.get("timestamp"))
    kind = origin.get("kind") if isinstance(origin, dict) else None
    base = {"text": text, "images": images, "ts": ts, "uuid": uuid}
    if kind == "human" and not meta:
        return {**base, "by": "human"}
    if origin is None and not meta and prompt_source != "sdk":
        stripped = text.lstrip()
        if stripped.startswith(("<command-name>", "<command-message>")):
            name = TR._tag_inner(stripped, "command-name") or TR._tag_inner(stripped, "command-message")
            args = TR._tag_inner(stripped, "command-args")
            return {**base, "by": "human", "text": (name + " " + args).strip()}
        if stripped.startswith(("<local-command-stdout>", "<local-command-stderr>", "<local-command-caveat>", "<bash-stdout>", "<bash-stderr>")):
            return None   # the output of a command the person ran: part of no turn
        if not text and not images:
            return None
    if not text and not images:
        return None
    src, cont = _source(kind, text, meta)
    return {**base, "by": "other", "src": src, "cont": cont}


def _source(kind: object, text: str, meta: bool) -> tuple[dict, bool]:
    """(where a delivered message came from, whether it is a hook's follow-up to the turn before)."""
    if kind == "task-notification" or text.lstrip().startswith("<task-notification>"):
        return {"kind": "task", "name": ""}, False
    if kind == "peer" or text.startswith(TR.PEER_PREFIX):
        body = text[len(TR.PEER_PREFIX):].strip() if text.startswith(TR.PEER_PREFIX) else text
        head = body.split("\n", 1)[0].strip()
        m = _TAG_FROM_NAME.match(body)
        who = m.group(1).strip() if m else ""
        if not who:
            m = _HEAD_MSG.match(head) or _HEAD_FROM.match(head)
            who = m.group(1) if m else ""
        if who:
            low = who.lower()
            return ({"kind": "board", "name": ""} if low == "stackshot" else {"kind": "sala", "name": ""} if low == "sala"
                    else {"kind": "session", "name": who}), False
        tag = _HEAD_TAG.match(head)
        word = tag.group(1).lower() if tag else ""
        if word in ("stackshot", "board", "anchor"):
            return {"kind": "board", "name": ""}, False
        if word == "sala":
            return {"kind": "sala", "name": ""}, False
        return {"kind": "other", "name": ""}, False
    if kind == "plugin" or kind is None or meta:
        cont = text.startswith(_CONTINUATION_TEXT) or (kind == "plugin" and not text.lstrip().startswith("/") and "<local-command" not in text)
        return {"kind": "system", "name": ""}, cont
    return {"kind": "other", "name": ""}, False


def _phrase(entry: dict) -> str:
    """A short clipped phrase of what a delivered message was: its first line past the header, no markup."""
    text = entry.get("text") or ""
    if text.startswith(TR.PEER_PREFIX):
        text = text[len(TR.PEER_PREFIX):].strip()
    m = _TASK_SUMMARY.search(text)
    if m:
        return _clip(m.group(1), PHRASE_MAX)
    lines = [ln.strip() for ln in text.split("\n") if ln.strip()]
    keep = []
    for ln in lines:
        if not keep and ((_HEAD_FROM.match(ln) and len(ln) < 120) or _HEAD_MSG.match(ln)):
            continue          # the `from: NAME` / `[stackshot message] from NAME · time` header line
        if ln.startswith("<cross-session-message"):
            ln = re.sub(r"^<cross-session-message[^>]*>\s*", "", ln)
            if not ln:
                continue
        keep.append(ln)
    first = keep[0] if keep else (lines[0] if lines else "")
    first = re.sub(r"^\[(?:stackshot|sala|anchor|board)[^\]\n]{0,60}\]\s*", "", first, flags=re.I)   # a leading [stackshot] / [sala op 123] tag
    return _clip(_plain(first).lstrip("> "), PHRASE_MAX)


def _plain(line: str) -> str:
    """One line without markdown: a link keeps its text, emphasis and code marks go."""
    line = _MD_LINK.sub(r"\1", line)
    line = re.sub(r"https?://\S+", "a link", line)
    return re.sub(r"[`*_]+", "", line).strip()


def _last_line(text: str) -> str:
    """The last line of a reply that is not a footer note (the Write-up and Board lines and what follows them), shortened."""
    lines = [ln.strip() for ln in text.split("\n") if ln.strip()]
    for i, ln in enumerate(lines):
        if i > 0 and _FOOTER_START.match(_plain(ln)):
            lines = lines[:i]
            break
    return _clip(_plain(lines[-1]).lstrip("-\u2022 "), DID_MAX) if lines else ""


def _mark_re(owner: str) -> re.Pattern:
    names = {owner.strip(), "owner", "the owner"}
    alt = "|".join(re.escape(n) for n in sorted((n for n in names if n), key=len, reverse=True))
    return re.compile(r"^\s*\[for (?:%s)\][ \t]*:?[ \t]*\n?" % alt, re.I)


def reply_of(d: dict, strict: bool) -> dict | None:
    """{"text", "ts", "uuid"} when an assistant line is a final reply (module docstring, TURNS), else None."""
    if d.get("type") != "assistant" or d.get("isSidechain") or d.get("isMeta"):
        return None
    msg = d.get("message")
    if not isinstance(msg, dict) or msg.get("model") == "<synthetic>":
        return None
    stop = msg.get("stop_reason")
    if stop == "tool_use" or (strict and stop is None):
        return None
    text, _ = _texts(msg.get("content"))
    text = text.strip()
    if not text:
        return None
    return {"text": text[:TEXT_MAX], "ts": _ms(d.get("timestamp")), "uuid": d.get("uuid") or ""}


class Turn:
    __slots__ = ("by", "user", "src", "replies", "open", "start_ts", "uuid")

    def __init__(self, by: str, user: dict | None, src: dict | None, ts: int | None, uuid: str):
        self.by, self.user, self.src, self.replies, self.open = by, user, src, [], True
        self.start_ts, self.uuid = ts, uuid


def build_turns(lines, strict: bool = False) -> list[Turn]:
    """Turns from parsed transcript lines (dicts), in file order (the module docstring has the rule)."""
    turns: list[Turn] = []
    cur: Turn | None = None
    for d in lines:
        if not isinstance(d, dict):
            continue
        r = reply_of(d, strict)
        if r is not None:
            if cur is not None:
                cur.replies.append(r)
                cur.open = False
            continue
        if d.get("type") == "assistant":
            continue
        e = classify_user(d)
        if e is None:
            continue
        if e["by"] == "human":
            if cur is not None and cur.open:
                if cur.by != "human":    # they spoke into a turn something else started: it is theirs now
                    cur.by, cur.src = "human", None
                if cur.user is None:
                    cur.user = e
                else:
                    cur.replies.append({"text": "", "ts": None, "uuid": "", "extra_user": e})   # a second message in one open turn
                continue
            cur = Turn("human", e, None, e["ts"], e["uuid"])
            turns.append(cur)
            continue
        # delivered
        if cur is not None and cur.open:
            continue
        if e.get("cont") and cur is not None and not cur.open and cur.replies:
            cur.open = True            # a hook's follow-up: the same turn goes on
            continue
        cur = Turn("other", None, {**e["src"], "text": e["text"], "images": e["images"]}, e["ts"], e["uuid"])
        turns.append(cur)
    return turns


def _read_window(path: Path, size: int, window: int) -> list[dict]:
    start = max(0, size - window)
    with path.open("rb") as f:
        f.seek(start)
        raw = f.read(size - start)
    parts = raw.split(b"\n")
    if start > 0:
        parts = parts[1:]          # cut mid-line
    if parts and parts[-1] and not parts[-1].endswith(b"}"):
        parts = parts[:-1]         # a line still being written
    out = []
    for p in parts:
        if not p or (b'"user"' not in p and b'"assistant"' not in p and b'"queued_command"' not in p):
            continue
        try:
            d = json.loads(p)
        except ValueError:
            continue
        if isinstance(d, dict) and d.get("type") in ("user", "assistant", "attachment"):
            out.append(d)
    return out


def day_start_ms(now_ms: int, zone: object) -> int:
    """Midnight today, in `zone` (a tzinfo), as epoch milliseconds."""
    now = datetime.fromtimestamp(now_ms / 1000, tz=timezone.utc).astimezone(zone)
    return int(now.replace(hour=0, minute=0, second=0, microsecond=0).timestamp() * 1000)


def read_turns(path: Path, now_ms: int, zone: object, strict: bool = False) -> tuple[list[Turn], bool]:
    """(the turns at the end of the transcript, whether the read reached back to the start of today). The window grows from the end until it
    holds TURNS_WANTED turns and reaches back before today began, or hits WINDOW_CAP (then `reached` is False and a count of today is a floor)."""
    try:
        size = path.stat().st_size
    except OSError:
        return [], True
    midnight = day_start_ms(now_ms, zone)
    window = WINDOW_FIRST
    while True:
        lines = _read_window(path, size, window)
        turns = build_turns(lines, strict)
        whole = window >= size
        first_ts = next((t.start_ts for t in turns if t.start_ts), None)
        reached = whole or (first_ts is not None and first_ts < midnight)
        if (reached and len(turns) >= TURNS_WANTED) or whole or window >= WINDOW_CAP:
            if not whole and turns and not reached:
                pass
            return turns, bool(reached)
        window = min(window * 4, WINDOW_CAP)


def entries(turns: list[Turn], owner: str, limit: int = 120) -> list[dict]:
    """The page's entries, in file order, from the last `limit` turns. Each is one of:
      {"k": "me", "ts", "id", "text", "images"}                           what the person typed
      {"k": "reply", "ts", "id", "text"}                                  the final reply of a turn they started
      {"k": "own", "ts", "id", "text"}                                    a marked reply of a turn something else started
      {"k": "kept", "ts", "id", "src": {kind, name}, "what", "did", "open"}  a hidden turn, one quiet line
    A turn the person started shows its replies that end a turn (more than one when a hook sent the turn back); an unmarked hidden turn shows
    nothing but its kept line."""
    mark = _mark_re(owner)
    out: list[dict] = []
    for t in turns[-limit:]:
        if t.by == "human":
            u = t.user
            if u is not None:
                out.append({"k": "me", "ts": u["ts"], "id": u["uuid"], "text": u["text"][:TEXT_MAX], "images": u["images"]})
            for r in t.replies:
                if r.get("extra_user"):
                    x = r["extra_user"]
                    out.append({"k": "me", "ts": x["ts"], "id": x["uuid"], "text": x["text"][:TEXT_MAX], "images": x["images"]})
                elif r["text"]:
                    out.append({"k": "reply", "ts": r["ts"], "id": r["uuid"], "text": r["text"]})
            continue
        last = next((r for r in reversed(t.replies) if r["text"]), None)
        if last is not None and mark.match(last["text"]):
            body = mark.sub("", last["text"], count=1).strip()
            if body:
                out.append({"k": "own", "ts": last["ts"], "id": last["uuid"], "text": body})
                continue
        src = t.src or {"kind": "other", "name": ""}
        out.append({"k": "kept", "ts": t.start_ts, "id": t.uuid, "src": {"kind": src["kind"], "name": src.get("name", "")},
                    "what": _phrase(src) if src.get("text") is not None else "", "did": _last_line(last["text"]) if last else "",
                    "open": last is None})
    return out


def kept_today(turns: list[Turn], owner: str, midnight_ms: int) -> int:
    """How many hidden turns started today (since `midnight_ms`) and were not marked for the person."""
    mark = _mark_re(owner)
    n = 0
    for t in turns:
        if t.by == "human" or (t.start_ts or 0) < midnight_ms:
            continue
        last = next((r for r in reversed(t.replies) if r["text"]), None)
        if last is not None and mark.match(last["text"]) and mark.sub("", last["text"], count=1).strip():
            continue
        n += 1
    return n
