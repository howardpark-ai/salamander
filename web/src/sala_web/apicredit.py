"""The shared API-credit refusal record, read-only (salamander lib/api_credit.py, "the shared record").

A job that spends the API key's credit (sala's briefings, the sdk lane, sdk-pane) writes this file when the key's call
comes back "credit balance is too low": {"refused_at": <epoch seconds>, "by": "<job>", "detail": "<text>"}. A successful key
call removes it. There is no balance API, so the refusal is the only sign that the key has no credit left. sala's lane
record (lane-state.tsv, lanestate.py) does not get this sign: the watch writes it only when a pane stops on the credit error,
so the pages could show the api lane active while the shared record holds a refusal. This module reads that record for
display only: the Overview's api card (api/credit) and the api lane's details page (api/lanes/<id>). The New session form,
`sala lane` and the automatic fallback do not read it through here. It never writes it, never retries the key, and returns
no detail text (only the time).
"""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path

# sala's own word for it (lib/watch.sh ld_limit_tick), which the page words in its language (sessions.js REASON_WORDS)
REASON = "credit used up"


def state_file() -> Path:
    """The record's path, as lib/api-credit.sh finds it: ${XDG_STATE_HOME:-$HOME/.local/state}/api-credit/state.json."""
    base = os.environ.get("XDG_STATE_HOME") or str(Path(os.environ.get("HOME") or "~").expanduser() / ".local" / "state")
    return Path(base) / "api-credit" / "state.json"


def refusal(path: Path | None = None) -> dict | None:
    """{"reason": REASON, "since": ISO UTC} when the record holds a refusal; None when there is no record, it cannot be
    read or parsed, or it holds no refused_at. None means "no refusal known", never "has credit"."""
    try:
        data = json.loads((path or state_file()).read_text(encoding="utf-8", errors="replace"))
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or not isinstance(data.get("refused_at"), (int, float)) or isinstance(data.get("refused_at"), bool):
        return None
    try:
        since = datetime.fromtimestamp(data["refused_at"], tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except (OverflowError, OSError, ValueError):
        return None
    return {"reason": REASON, "since": since}
