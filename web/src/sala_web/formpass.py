"""The pass the New session form's calls carry in place of the machine token (docs/stackshot-contracts.md, "A caller's own key").

sala keeps a key of its own for stackshot (`sala stackshot-key enroll`, lib/stackshot_key.py) and trades a signed claim for a pass that lasts ten minutes. The form's calls
(`POST /client/project-agent`, the For you list's two writes and the color combos writes) go with that pass where the machine token went; nothing else does.

The signing needs the `cryptography` package, which this app's own environment does not carry, so the pass is asked of lib/stackshot_key.py through the system python3
(`stackshot_key.py form-pass`, its answer read from a pipe: the pass is never on a command line, in a log, in a page or in an error text). The cache that script keeps
(a folder under $XDG_RUNTIME_DIR, mode 700) is shared with the shell side, so a pass traded by `sala spawn` serves this app too, and the other way round.

Never required: no key, a key still waiting, a server that says no, a missing script or package, a timeout = None here, and the caller uses the machine token as it always did.
SALA_STACKSHOT_PASS=off skips the step (what the tests set); SALA_STACKSHOT_KEY_PY names the script (a test's stand-in)."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

TIMEOUT = 20.0
OFF = ("off", "0", "no", "false")


def _script() -> Path | None:
    v = os.environ.get("SALA_STACKSHOT_KEY_PY")
    cands = [Path(v)] if v else [Path(__file__).resolve().parents[3] / "lib" / "stackshot_key.py", Path.home() / "salamander" / "lib" / "stackshot_key.py"]
    for p in cands:
        if p.is_file():
            return p
    return None


def _run(verb: str, base: str) -> subprocess.CompletedProcess | None:
    script = _script()
    if script is None:
        return None
    env = dict(os.environ)
    env["STACKSHOT_URL"] = base      # the claim's audience is the address this call goes to
    try:
        return subprocess.run(["python3", str(script), verb], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=TIMEOUT, env=env, check=False)
    except (OSError, subprocess.SubprocessError):
        return None


def form_pass(base: str) -> str | None:
    """A pass for a form call to the server at `base`, or None (use the machine token). Blocking: run it where the call is made (a thread)."""
    if os.environ.get("SALA_STACKSHOT_PASS", "").strip().lower() in OFF:
        return None
    p = _run("form-pass", base)
    if p is None or p.returncode != 0:
        return None
    pw = p.stdout.decode("ascii", "replace").strip()
    return pw if pw.startswith("ssp_") and pw.isprintable() and " " not in pw else None


def forget(base: str) -> None:
    """The server refused the pass (a restart of the server ends every pass): drop the cached one so the next call trades again."""
    _run("forget-pass", base)


