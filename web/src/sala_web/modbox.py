"""Ask a pane's claude, through sala's in-session mod, what its prompt box really holds.

The send path reads the pane's screen to tell whether the box holds the message it just pasted. When the screen cannot be
read as a box (a scrolled box, a layout it does not know) the answer is "missing" and the message sits in the pane unsent.
The mod (mod/hooks/register.ts) answers a `draft` request with the prompt box's own text, no screen involved, which is the
way to know it. This module is the Python side of that request, the same one lib/common.sh makes (`mod_request`):

  1. the session's registry row (<claude_dir>/sessions/<pid>.json) gives its id and its messaging socket;
  2. the mod's presence stamp (<run dir>/<session id>.json) must say present, for that session, version 1 or later, and
     be written no earlier than 2 s before the process started: a pane resumed without the mod after a run with it has
     an old stamp, and a pane with no stamp has no mod. Either way there is nobody to ask;
  3. one line, `[sala-mod] draft <reqid>` plus the note for the model should the mod not take it, goes to the socket as the
     JSON the CLI's messaging socket takes (lib/common.sh `session_push`);
  4. the reply, `<run dir>/<session id>.<reqid>.reply.json`, is polled for a short while and removed once read.

`draft` returns the text, or None for every way this can fail (no row, no stamp, an old stamp, no socket, a refused push,
no reply in time, a reply that is not ok). None means "the mod could not say", and the caller then does what it did before
the mod was asked: it refuses. Nothing here sends a key, and the text is returned to the caller and never logged here.
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import secrets
import stat
import time
import unicodedata
from dataclasses import dataclass
from pathlib import Path

from .config import Settings

MARK = "[sala-mod]"
MOD_VERSION = 1            # the oldest mod protocol this side speaks (lib/common.sh SALA_MOD_VERSION)
REPLY_WAIT = 2.0           # seconds the reply is waited for (the shell side waits 3)
POLL = 0.05
PUSH_TIMEOUT = 1.0
NOTE = ("(An automatic control line from salamander for its in-session mod. If you can read this, the mod is not loaded: "
        "ignore it and do nothing.)")
REQID_RE = re.compile(r"[A-Za-z0-9_-]{1,64}")
MAX_REPLY = 1024 * 1024    # a reply holds the box's text; a larger file is not one


def run_dirs(settings: Settings) -> list[Path]:
    """The folders the mod writes in, most likely first (lib/common.sh `mod_run_dirs`): $XDG_RUNTIME_DIR/sala/mod as the
    pane's claude saw it, else the state folder's mod/ (the mod's own fallback when XDG_RUNTIME_DIR is unset). Both are
    looked in, so a server and a pane started with different environments still meet."""
    dirs = []
    xdg = os.environ.get("XDG_RUNTIME_DIR")
    if xdg:
        dirs.append(Path(xdg) / "sala" / "mod")
    dirs.append(settings.sala_state_dir / "mod")
    return dirs


def process_start(pid: int) -> float | None:
    """When the process started, epoch seconds, from /proc (start ticks of /proc/<pid>/stat plus the boot time), or None."""
    try:
        stat_text = Path(f"/proc/{pid}/stat").read_text()
        rest = stat_text.rsplit(")", 1)[1].split()
        ticks = int(rest[19])
        btime = next(int(ln.split()[1]) for ln in Path("/proc/stat").read_text().splitlines() if ln.startswith("btime "))
    except (OSError, IndexError, ValueError, StopIteration):
        return None
    return btime + ticks / os.sysconf("SC_CLK_TCK")


def _read_json(path: Path) -> dict | None:
    try:
        with open(path, "rb") as f:
            raw = f.read(MAX_REPLY + 1)
        if len(raw) > MAX_REPLY:
            return None
        v = json.loads(raw)
    except (OSError, ValueError):
        return None
    return v if isinstance(v, dict) else None


def target(settings: Settings, pid: int) -> tuple[str, str, Path] | None:
    """(session id, messaging socket, run folder) of a pane's claude whose mod answers, else None: the same tests as
    lib/common.sh `_mod_target_r`, in the same order."""
    row = _read_json(settings.sessions_dir / f"{pid}.json")
    if row is None:
        return None
    sid, sock = row.get("sessionId"), row.get("messagingSocketPath")
    if not isinstance(sid, str) or not sid or "/" in sid or not isinstance(sock, str) or not sock:
        return None
    try:
        if not stat.S_ISSOCK(os.stat(sock).st_mode):
            return None
    except OSError:
        return None
    started = process_start(pid)
    if started is None:
        return None
    for d in run_dirs(settings):
        st = _read_json(d / f"{sid}.json")
        if st is None:
            continue
        version, at = st.get("version"), st.get("at")
        if (st.get("present") is not True or st.get("sessionId") != sid
                or isinstance(version, bool) or not isinstance(version, int) or version < MOD_VERSION
                or isinstance(at, bool) or not isinstance(at, (int, float))):
            continue
        # written before this process started (2 s of slack): a pane resumed without the mod after a run with it
        if at / 1000 < started - 2:
            continue
        return sid, sock, d
    return None


async def _push(sock: str, text: str) -> bool:
    """One JSON line on the session's messaging socket, the shape lib/common.sh `session_push` writes."""
    line = json.dumps({"type": "user", "message": {"role": "user", "content": text}}) + "\n"
    writer = None
    try:
        _reader, writer = await asyncio.wait_for(asyncio.open_unix_connection(sock), PUSH_TIMEOUT)
        writer.write(line.encode())
        await asyncio.wait_for(writer.drain(), PUSH_TIMEOUT)
        return True
    except (OSError, asyncio.TimeoutError):
        return False
    finally:
        if writer is not None:
            writer.close()
            try:
                await asyncio.wait_for(writer.wait_closed(), PUSH_TIMEOUT)
            except (OSError, asyncio.TimeoutError):
                pass


async def _ask(settings: Settings, pid: int, verb: str, payload: dict | None = None, wait: float = REPLY_WAIT) -> dict | None:
    """One request to the pane's mod and its reply, or None for every way this can fail. `payload`, when given, goes to a
    file beside the reply (<session id>.<reqid>.fill.json, written whole under a temp name, owner-only): a line on the
    socket cannot carry a newline, and the text of a message is never on the line, which a pane whose mod did not load would
    show its model. The mod reads the file and removes it; it is removed here too, whatever happened."""
    found = await asyncio.to_thread(target, settings, pid)
    if found is None:
        return None
    sid, sock, folder = found
    reqid = f"{int(time.time())}-{os.getpid()}-{secrets.token_hex(4)}"
    if not REQID_RE.fullmatch(reqid):
        return None
    reply = folder / f"{sid}.{reqid}.reply.json"
    body = folder / f"{sid}.{reqid}.fill.json"
    try:
        if payload is not None and not await asyncio.to_thread(_write_private, body, payload):
            return None
        if not await _push(sock, f"{MARK} {verb} {reqid}\n{NOTE}"):
            return None
        deadline = time.monotonic() + wait
        while True:
            got = await asyncio.to_thread(_read_json, reply)
            if got is not None:
                break
            if time.monotonic() >= deadline:
                return None
            await asyncio.sleep(POLL)
    finally:
        await asyncio.to_thread(lambda: (reply.unlink(missing_ok=True), body.unlink(missing_ok=True)))
    if got.get("ok") is not True or got.get("reqid") != reqid:
        return None
    return got


def _write_private(path: Path, value: dict) -> bool:
    """`value` as JSON in `path`, owner-only, whole or not at all (a temp name beside it, then a rename)."""
    tmp = path.with_name(path.name + f".tmp-{secrets.token_hex(4)}")
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(value, f, ensure_ascii=False)
        os.replace(tmp, path)
        return True
    except OSError:
        try:
            tmp.unlink(missing_ok=True)
        except OSError:
            pass
        return False


async def draft(settings: Settings, pid: int, wait: float = REPLY_WAIT) -> str | None:
    """The text of the prompt box of the claude with this pid, as the mod reads it, or None when the mod could not say."""
    got = await _ask(settings, pid, "draft", wait=wait)
    text = None if got is None else got.get("text")
    return text if isinstance(text, str) else None


@dataclass(frozen=True)
class Filled:
    """The mod's answer to a `fill` (the engine's own answer of `$.prompt.fill`): whether the box took the text, why not when
    the engine refused (`refusal`: "dialog" while a typed dialog or the permission dialog holds the keys, "no_composer",
    "unanswered"), the box's text afterwards (the current draft when refused) and the caret."""
    is_filled: bool
    refusal: str | None
    text: str
    cursor: int


FILL_MODES = ("replace", "append", "insert")
MAX_FILL = 128 * 1024      # characters a fill carries; a longer message is not asked about (the reply holds it back as well)


async def fill(settings: Settings, pid: int, text: str, mode: str = "replace", wait: float = REPLY_WAIT) -> Filled | None:
    """Put `text` in the prompt box of the claude with this pid through its mod (mode: replace, append or insert at the
    caret), or None when the mod could not say: no mod, a mod older than the verb (it answers "unknown", or not at all),
    no reply in time, a reply that is not ok or not shaped as an answer. `fill("", "insert")` changes nothing and says what
    the box holds and whether a dialog holds the keys: the probe. The box is the CLI's own: it drops zero-width characters,
    NUL, BEL and ESC and turns CRLF into LF, so `Filled.text` is what to compare, never `text`."""
    if mode not in FILL_MODES or len(text) > MAX_FILL:
        return None
    got = await _ask(settings, pid, "fill", {"text": text, "mode": mode}, wait)
    if got is None:
        return None
    done, refusal, box, cursor = got.get("isFilled"), got.get("refusal"), got.get("text"), got.get("cursor")
    if (not isinstance(done, bool) or not isinstance(box, str) or isinstance(cursor, bool) or not isinstance(cursor, int)
            or not (refusal is None or isinstance(refusal, str))):
        return None
    return Filled(done, refusal, box, cursor)


def normalize(text: str) -> str:
    """A text as the CLI's prompt box holds it, for comparing what was filled with what was meant: CRLF and CR become LF, the
    code points a terminal draws as nothing (zero-width characters, NUL, BEL, ESC, every other control and format character
    but newline and tab) are dropped, accents are NFC, and the end is trimmed (Enter drops the trailing spaces and newlines of
    what it submits). Leading spaces are kept: they are the owner's."""
    t = text.replace("\r\n", "\n").replace("\r", "\n")
    t = "".join(c for c in t if c in "\n\t" or unicodedata.category(c) not in ("Cc", "Cf"))
    return unicodedata.normalize("NFC", t).rstrip()
