"""The lanes' names as sala says them, read-only (the NAMES table of `sala lane names --json`).

A lane has a code (subscription-1, api, bedrock, ...) and a display name (the word sala gives it); the name is sala's to
choose and to change, so this app holds none of its own: no display name is written anywhere in this package. sala prints the
table with `sala lane names --json`, and writes the same document to `lane-names.json` in its state directory:

    {"lanes": [{"code": "subscription-1", "display": "<name>", "aliases": ["max"]}, ...]}      every known lane; aliases [] when none

`LaneNames.get()` is that table, in this order: what the command prints now (a short timeout), else the file in sala's state
directory (a sala that is not on the PATH, or one that has no such command yet), else the last good table this process had, else
the codes alone (display = code: "the code itself", never a baked-in name). The answer is kept TTL seconds, so a page that asks
every minute starts the command about once. `GET /api/lane-names` returns it; the page reads each lane's name from there
(static/shared.js laneLabel). Nothing here writes a file; the names carry no path and no secret.
"""

from __future__ import annotations

import asyncio
import json
import re
import time
from pathlib import Path
from typing import Awaitable, Callable

from . import lanestate as LS

TIMEOUT = 4.0                 # `sala lane names --json`: past this the saved file answers
TTL = 60.0                    # an answer is kept this long
FILE = "lane-names.json"      # in sala's state directory, written by sala beside lane-state.tsv
CODE_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")   # the lane id shape of lanes.LANE_ID_RE
DISPLAY_MAX = 40
_CTRL = re.compile(r"[\x00-\x1f\x7f]")


def parse(text: str) -> list[dict] | None:
    """The lane rows of the table's document (the command's output, noise before the JSON tolerated, or the file's text); None
    when it is no such document or holds no usable row. A row with a bad code or an empty name is skipped; aliases are the words
    that are lane codes in shape, as a list."""
    start = text.find("{")
    if start < 0:
        return None
    try:
        doc, _ = json.JSONDecoder().raw_decode(text[start:])
    except ValueError:
        return None
    lanes = doc.get("lanes") if isinstance(doc, dict) else None
    if not isinstance(lanes, list):
        return None
    rows, seen = [], set()
    for r in lanes:
        if not isinstance(r, dict):
            continue
        code, display = r.get("code"), r.get("display")
        if not isinstance(code, str) or not CODE_RE.match(code) or code in seen:
            continue
        name = re.sub(r"\s+", " ", _CTRL.sub(" ", display)).strip()[:DISPLAY_MAX] if isinstance(display, str) else ""
        al = r.get("aliases")
        aliases = [a for a in al if isinstance(a, str) and CODE_RE.match(a)] if isinstance(al, list) else []
        seen.add(code)
        rows.append({"code": code, "display": name or code, "aliases": aliases})
    return rows or None


def codes_only() -> list[dict]:
    """The last resort: each lane the app knows, its display the code itself, its aliases the old words read as it."""
    codes = [*dict.fromkeys([*LS.RENAMED.values(), "api", "bedrock"])]
    return [{"code": c, "display": c, "aliases": [a for a, n in LS.ALIASES.items() if n == c]} for c in codes]


def label(rows: list[dict], lane: str) -> str:
    """The display name of a lane given by its code or any alias (sala's, then this app's own old words); the code when the table
    has no such lane. Not lower-cased: the page does that for a pill."""
    word = LS.norm(lane) if isinstance(lane, str) else ""
    for r in rows:
        if word == r["code"] or word in r["aliases"] or lane in r["aliases"]:
            return r["display"]
    return word


class LaneNames:
    def __init__(self, run: Callable[[], Awaitable[str | None]], state_dir: Path, ttl: float = TTL):
        """run: starts `sala lane names --json` and gives its output, None when it did not answer (a missing or failing command)."""
        self._run = run
        self._file = Path(state_dir) / FILE
        self._ttl = ttl
        self._rows: list[dict] | None = None   # the last good table
        self._at = 0.0
        self._lock = asyncio.Lock()

    def _from_file(self) -> list[dict] | None:
        try:
            return parse(self._file.read_text(encoding="utf-8", errors="replace"))
        except OSError:
            return None

    async def rows(self) -> list[dict]:
        async with self._lock:
            if self._rows is not None and time.monotonic() - self._at < self._ttl:
                return self._rows
            try:
                out = await self._run()
            except (OSError, TimeoutError, asyncio.TimeoutError):
                out = None
            got = parse(out) if out else None
            if got is None:
                got = self._from_file()
            if got is not None:
                self._rows, self._at = got, time.monotonic()
                return got
            if self._rows is not None:
                self._at = time.monotonic() - self._ttl + 5.0   # the table kept, asked again in a few seconds
                return self._rows
            return codes_only()   # nothing kept: asked again at the next request

    async def get(self) -> dict:
        return {"lanes": await self.rows()}
