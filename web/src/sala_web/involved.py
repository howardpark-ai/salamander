"""The open items the chat session is the contact of or an observer on, for the second tab of the chat strip ("On it").

stackshot serves them in one read, `GET <server>/client/involved?key=<session>` with this machine's token as a bearer (the same token and address
files board.py reads): {"items": [{"shown", "subject", "url", "mover", "held", "until", "state_updated", ...}]}, open items only, no cap, the last
written first. The key is the chat session's configured name (config.chat_session) and nothing else: no request of a page names it. This module reads
and keeps the answer the way yourmove.py keeps the Your move list (swr.py):

  - one refresh per TTL in the background, whatever the number of pages polling; a page view never makes a request of its own and is served at once
    from the last good answer; the read itself has a 3 s timeout;
  - a failed read keeps the last good answer, and `items()` hands it out while it is no older than STALE_MAX (10 minutes); older, or never read (a
    server without this read answers 404, a missing token), `items()` is None and the strip is the Your move line alone, with nothing said;
  - an answer belongs to the session it was asked for: after the setting names another session, the old one's list is never handed out;
  - the answer is kept under the state dir as text so a restart has it too: never the token, which goes only in the Authorization header and in no
    error text, log line or file.

A row is passed on as {"id": shown, "subject", "url", "mover", "held", "until", "since": state_updated}, in the order sent, each id once. `url` is kept
only when it is a whole http(s) address (a server with no web address of its own sends a bare path, which would lead to sala's own host: no link then).
`until` is a day "YYYY-MM-DD" or None, `since` epoch seconds or None. An empty list is an answer (the tab says there is nothing).
"""

from __future__ import annotations

import asyncio
import datetime
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from . import board as B
from . import swr as SWR
from . import yourmove as YM

TTL = 30.0           # one read per 30 s, however many pages poll
ERROR_RETRY = 30.0   # after a failure, try again at the next poll
TIMEOUT = 3.0        # the read's own timeout: the page never waits on it, the background refresh does
STALE_MAX = 600.0    # the last good list stands this long (seconds) while the read keeps failing
MOVER_MAX = 200
_DAY = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}")


def fetch_involved(url: str, token: str, key: str) -> object:
    """GET /client/involved?key=<session> (blocking; run it in a thread). Raises board.Unauthorized on 401, RuntimeError otherwise, with a message
    that carries neither the token nor the URL."""
    req = urllib.request.Request(f"{url}/client/involved?{urllib.parse.urlencode({'key': key})}",
                                 headers={"Authorization": f"Bearer {token}", "User-Agent": "sala-web"})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        if e.code == 401:
            raise B.Unauthorized() from None
        raise RuntimeError(f"stackshot answered HTTP {e.code}") from None
    except urllib.error.URLError as e:
        raise RuntimeError(f"stackshot unreachable ({str(e.reason)[:80]})") from None
    except (TimeoutError, OSError) as e:
        raise RuntimeError(f"stackshot unreachable ({type(e).__name__})") from None
    except ValueError:
        raise RuntimeError("stackshot sent an unreadable answer") from None


def _day(v: object) -> str | None:
    if not isinstance(v, str) or not _DAY.fullmatch(v):
        return None
    try:
        datetime.date.fromisoformat(v)
    except ValueError:
        return None
    return v


def _seconds(v: object) -> int | None:
    # the upper bound keeps out what no clock says (and what a browser's date cannot hold); NaN fails both comparisons
    return int(v) if isinstance(v, (int, float)) and not isinstance(v, bool) and 0 < v < 1e11 else None


def parse(body: object) -> list[dict]:
    """The tab's rows of one answer, in the order sent, each id once. RuntimeError for an answer that is no list of items."""
    items = body.get("items") if isinstance(body, dict) else None
    if not isinstance(items, list):
        raise RuntimeError("stackshot sent an unexpected answer")
    out: list[dict] = []
    seen: set[str] = set()
    for it in items:
        if not isinstance(it, dict):
            continue
        shown = str(it.get("shown") or "").strip()[:YM.SHOWN_MAX]
        if not shown or shown in seen:
            continue
        seen.add(shown)
        url = str(it.get("url") or "").strip()
        mover = it.get("mover")
        out.append({"id": shown, "subject": " ".join(str(it.get("subject") or "").split())[:YM.SUBJECT_MAX],
                    "url": url[:500] if url.startswith(("http://", "https://")) else "",
                    "mover": " ".join(mover.split())[:MOVER_MAX] if isinstance(mover, str) else "",
                    "held": it.get("held") is True, "until": _day(it.get("until")), "since": _seconds(it.get("state_updated"))})
    return out


class InvolvedCache:
    """One session's list, served at once from the last good answer and refreshed in the background once it is TTL old."""

    def __init__(self, token_path: Path, url_path: Path, state_path: Path | None = None, fetch=fetch_involved):
        self.token_path = token_path
        self.url_path = url_path
        self.fetch = fetch
        self._swr = SWR.Revalidating(state_path, TTL, ERROR_RETRY, {"items": []},
                                     valid=lambda d: isinstance(d.get("items"), list) and isinstance(d.get("key"), str))
        self._key = self._swr.state.get("key")   # the session the reads ask for: a saved answer's own until a call names another

    def items(self, key: str) -> list[dict] | None:
        """The list of the session `key` now (a refresh started when one is due, never waited for): the last good answer for that session while it is
        no older than STALE_MAX, else None (never read, the reads failing for too long, or the answer held is another session's)."""
        if key != self._key:
            self._key = key
            self._swr.expire()
        doc = self._swr.serve(self._refresh)
        fetched = doc.get("fetchedAt")
        if doc.get("key") != key or not isinstance(fetched, int) or not isinstance(doc.get("items"), list):
            return None
        if time.time() - fetched / 1000 > STALE_MAX:
            return None
        return [x for x in doc["items"] if isinstance(x, dict)]

    async def _refresh(self) -> dict:
        key = self._key
        try:
            token, url = B.read_token(self.token_path), B.read_url(self.url_path)
        except B.ConfigError as e:
            raise SWR.Failed(str(e)) from None
        try:
            return {"key": key, "items": parse(await asyncio.to_thread(self.fetch, url, token, key))}
        except B.Unauthorized:
            raise SWR.Failed(B.REFUSED) from None
        except RuntimeError as e:
            raise SWR.Failed(str(e)) from None
        except Exception as e:  # never str(e): an unexpected error could carry anything
            raise SWR.Failed(f"the involved items could not be read ({type(e).__name__})") from None
