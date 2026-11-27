"""The web UI's sighting for `sala where` (lib/where.py `seen`): the page request that came from the owner's own box.

The site is reached browser -> tailscaled TCP forward -> the local reverse proxy -> this app on its unix socket. The proxy reads the PROXY header
tailscaled sends and puts the visitor's tailnet address in X-Forwarded-For. The right-most entry is the one the local proxy added (a client may
prepend its own entries, never append), so it is the one read; a missing or non-address header does nothing. A visit through a public proxy
shows a public address, which no machine has, and a local call has no header: both record nothing.

Trust: the header is believed only because the socket is private to the owner (a unix socket in the owner's runtime folder, no TCP port): only the
local proxy can connect to it, so only it can set the last entry. Nothing here checks a peer address (the socket carries none).

Cost and safety: only the page itself counts (the main document and the terminal page; never a static file, an API call or a poll); one address
is handled at most once per 60 seconds in this process; the work (a short `python3 lib/where.py seen <address>` subprocess, 20 s limit) runs in a
daemon thread, and every error is swallowed, so a request is never slowed or failed. The mapping of an address to a box, and which record wins,
are lib/where.py's: this module only hands over the address.
"""

from __future__ import annotations

import ipaddress
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

THROTTLE_S = 60
TIMEOUT_S = 20
_MAX_ADDRESSES = 256    # the throttle table is bounded: past this, entries older than the window are dropped

_last: dict[str, float] = {}
_lock = threading.Lock()


def address_of(header: str | None) -> str | None:
    """The right-most entry of an X-Forwarded-For value, normalized, when it is an IP address; else None."""
    if not header:
        return None
    last = header.split(",")[-1].strip()
    try:
        return str(ipaddress.ip_address(last))
    except ValueError:
        return None


def _where_script() -> Path | None:
    for p in (Path(__file__).resolve().parents[3] / "lib" / "where.py", Path.home() / "salamander" / "lib" / "where.py"):
        if p.is_file():
            return p
    return None


def _env(settings) -> dict[str, str]:
    env = dict(os.environ)
    try:
        env["SALA_STATE_DIR"] = str(settings.sala_state_dir)
        if settings.fleet_names_file:
            env["SALA_FLEET_NAMES"] = str(settings.fleet_names_file)
        if settings.follow_machines_file:
            env["SALA_MACHINE_FOLLOW_MACHINES"] = str(settings.follow_machines_file)
    except Exception:
        pass
    return env


def _run(addr: str, settings) -> None:
    try:
        script = _where_script()
        if script is None:
            return
        subprocess.run([sys.executable, "-I", "-S", str(script), "seen", addr], env=_env(settings), capture_output=True, timeout=TIMEOUT_S)
    except Exception:
        pass


def _job(addr: str, settings) -> None:
    try:
        _run(addr, settings)
    except Exception:
        pass


def due(addr: str, now: float | None = None) -> bool:
    """True (and the address is stamped) when ADDR has not been handled in the last THROTTLE_S seconds."""
    now = time.monotonic() if now is None else now
    with _lock:
        t = _last.get(addr)
        if t is not None and now - t < THROTTLE_S:
            return False
        if len(_last) >= _MAX_ADDRESSES:
            for k in [k for k, v in _last.items() if now - v >= THROTTLE_S]:
                del _last[k]
            if len(_last) >= _MAX_ADDRESSES:
                return False
        _last[addr] = now
        return True


def note(request, settings) -> None:
    """Called by the handler of a page request: hand the visitor's address to `where seen`, in a background thread, at most once a minute per address."""
    try:
        addr = address_of(request.headers.get("x-forwarded-for"))
        if addr is None or not due(addr):
            return
        threading.Thread(target=_job, args=(addr, settings), daemon=True, name="where-seen").start()
    except Exception:
        pass
