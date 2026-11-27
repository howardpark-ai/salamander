"""The server's outbox: the messages the owner sends from a page, kept per session on disk until the session has taken them.

A message sent from any page goes to the session even while a turn runs (Claude Code queues it). What the page can not hand over at
once is HELD here, on the server, and sent when the pane can take it, in the order it was sent: a permission or question dialog is
open, the terminal's input box holds text, there is no input box, the session sleeps or its pane is gone. The browser keeps nothing
(it used to keep a sleeper's message in localStorage): a reload, a second tab and a phone all read the same list.

Text in the terminal's input line is never the owner's (he writes from the pages, never in the terminal sala drives), so it does not hold a message:
the sender clears the line first, and keeps what it cleared in a log of its own (ClearedLog, `<state dir>/outbox-cleared.jsonl`) so that it can be found.
A message waits only for what is not safe to press into: a dialog or overlay, no input box, a sleeping session, a pane that is not found.

One file per session, `<state dir>/outbox/<name>.json`, written whole to a temporary file and renamed into place (mode 700 for the
folder, 600 for a file). A message is an entry with a state:

  held       waiting: `reason` says for what (REASONS); only the oldest held message is tried, the rest wait behind it ("ahead")
  typing     being pasted into the pane right now (a restart in this state leaves it `failed`: it may or may not have gone in)
  queued     pasted and submitted; the session has it (in its input queue or already taken) and no transcript line shows it yet
  delivered  a transcript line shows the session took it
  withdrawn  the owner cancelled or edited it before it was typed
  failed     it could not be sent (`error` says why); the text stays, so Edit takes it back

Only held and failed messages can be taken back: once the text is in the session's pane it is the session's (taking it out of the
CLI's own queue needs a key sala does not send; that is a later step, and the answer is `tooLate` until then).

The matching of what the transcript shows (a user line, a queued_command attachment, a queue-operation line) is here as plain
functions, so that it is tested on made-up lines. Everything of the store runs on the event loop's thread, never in a worker.
"""

from __future__ import annotations

import json
import os
import re
import secrets
import time
from datetime import datetime
from pathlib import Path

HELD, TYPING, QUEUED, DELIVERED, WITHDRAWN, FAILED = "held", "typing", "queued", "delivered", "withdrawn", "failed"
STATES = (HELD, TYPING, QUEUED, DELIVERED, WITHDRAWN, FAILED)
ACTIVE = (HELD, TYPING)        # the states sala still owns
# what a held message waits for; the page words each (static/app.js, app.pend.ob.*)
REASONS = ("asleep",           # the session sleeps: its pane has no Claude (the page asks for the wake)
           "gone",             # no session of that name is listed now (it may be relaunching)
           "pane",             # the session's pane is not found, or is not the session's own
           "tmux",             # tmux did not answer
           "noInput",          # the pane shows no input box (a menu, a screen being drawn, a woken session still loading)
           "dialog",           # a permission or question dialog is open: only its option number or esc passes
           "draft",            # the terminal's input line holds text that sala could not clear (`detail` is that text)
           "ahead")            # an earlier message waits first
RETAIN_S = 6 * 3600            # a delivered, withdrawn or failed entry stays this long (the page shows the last states, then it is gone)
MAX_ENTRIES = 200
MAX_TEXT = 200_000
SLACK_MS = 3000                # a transcript line may be stamped this much before the entry's own clock


CLEARED_FILE = "outbox-cleared.jsonl"
CLEARED_MAX = 256 * 1024       # the log never grows past this: a write that would pass it keeps the newest half first


class NotFound(LookupError):
    pass


class TooLate(Exception):
    """The message is no longer sala's to take back (typed, queued or delivered); `entry` says which."""

    def __init__(self, entry: dict):
        super().__init__(entry["state"])
        self.entry = entry


_SAFE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,120}$")


def file_key(name: str) -> str:
    """The file stem a session name is kept under: the name itself when it is plain, else a made-safe form with a short hash,
    so that two odd names never share a file and no name can name a path."""
    if _SAFE_RE.match(name) and not name.endswith(".json"):
        return name
    import hashlib
    return re.sub(r"[^A-Za-z0-9._-]", "_", name).lstrip(".-")[:60] + "-" + hashlib.sha1(name.encode("utf-8", "replace")).hexdigest()[:10]


def _now_ms() -> int:
    return int(time.time() * 1000)


class Outbox:
    """The per-session lists, in memory and on disk. `version(name)` changes with every change, which is what an open stream compares."""

    def __init__(self, root: Path, clock=_now_ms):
        self.root = Path(root)
        self._clock = clock
        self._boxes: dict[str, list[dict]] = {}
        self._versions: dict[str, int] = {}
        self._scanned = False

    # ── disk ──────────────────────────────────────────────────────────────────────────────────────────────
    def _file(self, name: str) -> Path:
        return self.root / (file_key(name) + ".json")

    def _read(self, path: Path) -> tuple[str, list[dict]] | None:
        try:
            with open(path, "rb") as f:
                raw = f.read(32 * 1024 * 1024)
            d = json.loads(raw)
        except (OSError, ValueError):
            return None
        if not isinstance(d, dict) or not isinstance(d.get("name"), str) or not isinstance(d.get("messages"), list):
            return None
        out = []
        for e in d["messages"]:
            if isinstance(e, dict) and isinstance(e.get("id"), str) and e.get("state") in STATES and isinstance(e.get("text"), str):
                e.setdefault("uploads", [])
                out.append(e)
        return d["name"], out

    def _settle_after_restart(self, entries: list[dict]) -> bool:
        """An entry left `typing` by a stopped server may or may not have gone in: it is failed (its text stays, Edit takes it back), never resent."""
        changed = False
        for e in entries:
            if e["state"] == TYPING:
                e.update(state=FAILED, reason=None, error="sala-web restarted while this message was being typed; check the terminal before sending it again",
                         updated=self._clock())
                changed = True
        return changed

    def _load(self, name: str) -> list[dict]:
        box = self._boxes.get(name)
        if box is not None:
            return box
        got = self._read(self._file(name)) if self._file(name).exists() else None
        box = got[1] if got and got[0] == name else []
        self._boxes[name] = box
        self._versions.setdefault(name, 1)
        if self._settle_after_restart(box):
            self._save(name)
        return box

    def _save(self, name: str) -> None:
        box = self._boxes[name]
        cutoff = self._clock() - RETAIN_S * 1000
        box[:] = [e for e in box if e["state"] in (HELD, TYPING, QUEUED) or e.get("updated", 0) >= cutoff][-MAX_ENTRIES:]
        self._versions[name] = self._versions.get(name, 0) + 1
        path = self._file(name)
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.root, 0o700)
        tmp = path.with_name(f".{path.name}.{secrets.token_hex(4)}.tmp")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump({"version": 1, "name": name, "messages": box}, f, ensure_ascii=False)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise

    def _scan(self) -> None:
        """At the first look, every session's file in the folder is read, so that work left by a stopped server is picked up."""
        if self._scanned:
            return
        self._scanned = True
        try:
            files = sorted(self.root.glob("*.json"))
        except OSError:
            return
        for p in files:
            got = self._read(p)
            if got and got[0] not in self._boxes:
                self._boxes[got[0]] = got[1]
                self._versions.setdefault(got[0], 1)
                if self._settle_after_restart(got[1]):
                    self._save(got[0])

    # ── reading ───────────────────────────────────────────────────────────────────────────────────────────
    def version(self, name: str) -> int:
        self._load(name)
        return self._versions.get(name, 0)

    def entries(self, name: str) -> list[dict]:
        """The session's entries, oldest first, as copies (the page's view)."""
        return [dict(e) for e in self._load(name)]

    def get(self, name: str, mid: str) -> dict | None:
        for e in self._load(name):
            if e["id"] == mid:
                return e
        return None

    def names_with_work(self) -> list[str]:
        """Sessions that have a held, typing or queued entry: the ones the sender and the transcript check look at."""
        self._scan()
        return [n for n, box in self._boxes.items() if any(e["state"] in (HELD, TYPING, QUEUED) for e in box)]

    def counts(self, name: str) -> dict[str, int]:
        out: dict[str, int] = {}
        for e in self._load(name):
            out[e["state"]] = out.get(e["state"], 0) + 1
        return out

    def head(self, name: str) -> dict | None:
        """The message to try next: the oldest held one, and none while another is being typed."""
        box = self._load(name)
        if any(e["state"] == TYPING for e in box):
            return None
        return next((e for e in box if e["state"] == HELD), None)

    # ── writing ───────────────────────────────────────────────────────────────────────────────────────────
    def add(self, name: str, text: str, uploads: list[str], cid: str | None = None) -> tuple[dict, bool]:
        """A new held entry at the end of the list. A `cid` the list already has (the page asked twice) returns that entry, created False."""
        box = self._load(name)
        if cid:
            for e in box:
                if e.get("cid") == cid:
                    return e, False
        now = self._clock()
        e = {"id": secrets.token_hex(5), "cid": cid or "", "text": text[:MAX_TEXT], "uploads": list(uploads), "state": HELD, "reason": None,
             "detail": "", "error": "", "created": now, "updated": now, "sentAt": None, "attempts": 0, "resent": False,
             "pasted": False, "pid": None, "procStart": None, "sessionId": ""}
        box.append(e)
        self._save(name)
        return e, True

    def update(self, name: str, mid: str, **fields) -> dict:
        e = self.get(name, mid)
        if e is None:
            raise NotFound(mid)
        before = {k: e.get(k) for k in fields}
        if before == fields:
            return e      # nothing changed: nothing written, no new version for the stream to send
        e.update(fields)
        e["updated"] = self._clock()
        self._save(name)
        return e

    def withdraw(self, name: str, mid: str) -> dict:
        """The owner's cancel or edit: a held or failed message becomes withdrawn. Raises TooLate for one the pane has, NotFound for an unknown id.
        A withdrawn one asked for again is returned as it is."""
        e = self.get(name, mid)
        if e is None:
            raise NotFound(mid)
        if e["state"] == WITHDRAWN:
            return e
        if e["state"] not in (HELD, FAILED):
            raise TooLate(e)
        return self.update(name, mid, state=WITHDRAWN, reason=None, detail="")


# ── what the page is given ────────────────────────────────────────────────────────────────────────────────
PUBLIC = ("id", "cid", "text", "uploads", "state", "reason", "detail", "error", "created", "updated", "sentAt", "attempts", "resent")


def public(entries: list[dict]) -> list[dict]:
    """The entries as the page reads them. A held entry that is not the head says it waits for the one before it."""
    out = []
    seen_active = False
    for e in entries:
        v = {k: e.get(k) for k in PUBLIC}
        if e["state"] in ACTIVE:
            if seen_active and e["state"] == HELD:
                v["reason"] = "ahead"
            seen_active = True
        out.append(v)
    return out


# ── what the transcript shows ─────────────────────────────────────────────────────────────────────────────
_WRAP_RE = re.compile(r"</?pasted_content(?:\s+id=\"[^\"]*\")?\s*>")
_CHIP_RE = re.compile(r"\[Image #\d+\]")


def norm_text(text: object) -> str:
    """A message as the page and the transcript can both be compared: Claude Code's pasted_content wrapper and image chips out, whitespace collapsed
    (the same rule as the page's normText)."""
    return re.sub(r"\s+", " ", _CHIP_RE.sub(" ", _WRAP_RE.sub(" ", str(text or "")))).strip()


def ts_ms(ts: object) -> int | None:
    if isinstance(ts, (int, float)):
        return int(ts)
    if not isinstance(ts, str):
        return None
    try:
        return int(datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp() * 1000)
    except ValueError:
        return None


def rows_from_messages(msgs: list[dict]) -> list[tuple[int, str, int]]:
    """(time ms, normalized text, image count) of the owner's lines among the transcript messages sala reads (user lines and queued_command
    attachments both come as role user; a notice, a task notification and a command output are not text blocks)."""
    rows = []
    for m in msgs:
        if m.get("role") != "user":
            continue
        t = ts_ms(m.get("ts"))
        if t is None:
            continue
        blocks = m.get("blocks") or []
        text = norm_text("\n".join(b.get("text") or "" for b in blocks if b.get("kind") == "text"))
        n = sum(1 for b in blocks if b.get("kind") == "image")
        if text or n:
            rows.append((t, text, n))
    rows.sort(key=lambda r: r[0])
    return rows


def delivered_ids(queued: list[dict], rows: list[tuple[int, str, int]]) -> list[str]:
    """The ids among `queued` (oldest first, each with a sentAt) that the transcript rows show the session took.

    Claude Code may join messages queued together into one line ("T1 T2"), and a file's path is written before the text, so a row is
    read as the messages that begin it, in the order they were sent: the oldest undelivered message whose text is the start of the row
    (or its end, for a file's path before it) takes that part, and the rest of the row goes to the next. A message of images alone
    takes a row with no text. Nothing is matched earlier than the message's own time (less SLACK_MS)."""
    out: list[str] = []
    todo = [e for e in queued if e.get("sentAt")]
    for t, text, n in rows:
        rest = text
        while todo:
            e = todo[0]
            if t < e["sentAt"] - SLACK_MS:
                break
            want = norm_text(e["text"])
            if want:
                if rest.startswith(want):
                    rest = rest[len(want):].strip()
                elif rest.endswith(want):
                    rest = rest[:-len(want)].strip()
                else:
                    break
            elif not (e.get("uploads") and n and not rest):
                break
            out.append(e["id"])
            todo.pop(0)
            if not rest:
                break
    return out


def read_ops(path: Path, since_ms: int, max_bytes: int = 512 * 1024) -> list[dict]:
    """The queue-operation lines at the end of a transcript that are stamped `since_ms` or later: {"op", "ts", "text"} (text normalized, None when
    the line carries none: a dequeue, and an enqueue made during a compaction). The CLI writes these when a message is typed while it works
    (Claude Code 2.1.332; not a documented contract: nothing here acts on a line that is not in this shape)."""
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - max_bytes))
            raw = f.read()
            cut = size > max_bytes
    except OSError:
        return []
    lines = raw.split(b"\n")
    if cut:
        lines = lines[1:]    # the first line is a part
    out = []
    for ln in lines:
        if b'"queue-operation"' not in ln:
            continue
        try:
            d = json.loads(ln)
        except ValueError:
            continue
        if not isinstance(d, dict) or d.get("type") != "queue-operation" or not isinstance(d.get("operation"), str):
            continue
        t = ts_ms(d.get("timestamp"))
        if t is None or t < since_ms:
            continue
        c = d.get("content")
        out.append({"op": d["operation"], "ts": t, "text": norm_text(c) if isinstance(c, str) else None})
    out.sort(key=lambda o: o["ts"])
    return out


RESOLVING = ("remove", "dequeue", "popAll")


def lost_ids(queued: list[dict], ops: list[dict]) -> list[str]:
    """Of `queued` (oldest first; the caller has already taken out what the transcript shows delivered, and has found that the process these were
    sent to has ended), the ids with positive evidence that the session never took them: an enqueue line carrying exactly the message, and
    not as many remove, dequeue or popAll lines after the first as that enqueue's place in the line (the CLI's queue is first in, first out;
    popAll writes one line per message). A message with no such enqueue line is not named: a wrong "lost" would send it twice."""
    if not queued:
        return []
    start = min(e["sentAt"] for e in queued if e.get("sentAt")) - SLACK_MS
    enq = [o for o in ops if o["op"] == "enqueue" and o["ts"] >= start]
    resolved = sum(1 for o in ops if o["op"] in RESOLVING and o["ts"] >= start)
    out = []
    taken: set[int] = set()    # an enqueue line is one message's: two equal messages take one line each
    for e in queued:
        want = norm_text(e["text"])
        if not want or not e.get("sentAt"):
            continue
        for place, o in enumerate(enq):
            if place not in taken and o["text"] == want and o["ts"] >= e["sentAt"] - SLACK_MS:
                taken.add(place)
                if place >= resolved:
                    out.append(e["id"])
                break
    return out


class ClearedLog:
    """What sala emptied out of a pane's input line before it typed a message: one JSON object a line (`t` ms since the epoch, `session`, `text`), mode 600, under CLEARED_MAX bytes (a write that would pass it keeps the newest half first, through a
    temporary file renamed into place). The text is written before the keys that clear it, so that a crash between the two loses nothing."""

    def __init__(self, path: Path, clock=_now_ms):
        self.path = Path(path)
        self._clock = clock

    def append(self, session: str, text: str) -> None:
        line = json.dumps({"t": self._clock(), "session": session, "text": text[:MAX_TEXT]}, ensure_ascii=False) + "\n"
        data = line.encode("utf-8")
        self.path.parent.mkdir(parents=True, exist_ok=True)
        try:
            size = self.path.stat().st_size
        except OSError:
            size = 0
        if size + len(data) > CLEARED_MAX:
            self._keep_newest_half()
        fd = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            os.write(fd, data)
        finally:
            os.close(fd)

    def _keep_newest_half(self) -> None:
        try:
            raw = self.path.read_bytes()
        except OSError:
            return
        tail = raw[len(raw) // 2:]
        nl = tail.find(b"\n")
        tail = tail[nl + 1:] if nl >= 0 else b""     # the half starts on a whole line
        tmp = self.path.with_name(f".{self.path.name}.{secrets.token_hex(4)}.tmp")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(tail)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, self.path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise

    def read(self) -> list[dict]:
        try:
            lines = self.path.read_text(encoding="utf-8").splitlines()
        except OSError:
            return []
        out = []
        for ln in lines:
            try:
                d = json.loads(ln)
            except ValueError:
                continue
            if isinstance(d, dict):
                out.append(d)
        return out
