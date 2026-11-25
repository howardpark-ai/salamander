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


async def draft(settings: Settings, pid: int, wait: float = REPLY_WAIT) -> str | None:
    """The text of the prompt box of the claude with this pid, as the mod reads it, or None when the mod could not say."""
    found = await asyncio.to_thread(target, settings, pid)
    if found is None:
        return None
    sid, sock, folder = found
    reqid = f"{int(time.time())}-{os.getpid()}-{secrets.token_hex(4)}"
    if not REQID_RE.fullmatch(reqid):
        return None
    reply = folder / f"{sid}.{reqid}.reply.json"
    try:
        if not await _push(sock, f"{MARK} draft {reqid}\n{NOTE}"):
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
        await asyncio.to_thread(lambda: reply.unlink(missing_ok=True))
    text = got.get("text")
    if got.get("ok") is not True or got.get("reqid") != reqid or not isinstance(text, str):
        return None
    return text
