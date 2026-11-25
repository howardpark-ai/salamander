"""The owner's whole "Your move" group, for the chat page's Waiting on you strip.

The board feed (board.py) is asked once per live session, so it lists only the moves some session of this machine is tied to. stackshot
serves the whole group in one read, `GET <server>/client/your-move` with this machine's token as a bearer (the same token and address
files board.py reads): {"items": [{"shown", "subject", "url", "ask", "updated"}]}, every item of the home page's Your move group, no cap,
in the page's own order (the owner's longest wait first). This module reads it and keeps it the way board.py keeps the feed (swr.py):

  - one refresh per TTL in the background, whatever the number of pages polling; a page view never makes a request of its own and is
    served at once from the last good answer; the read itself has a 3 s timeout;
  - a failed read keeps the last good answer, and `items()` hands it out while it is no older than STALE_MAX (10 minutes), saying
    nothing is wrong; older, or never read, `items()` is None and the caller falls back to the board feed, so the strip is never emptier
    than it was before this read existed;
  - the answer is kept under the state dir as text (id, subject, url) so a restart has it too: never the token. The token goes only in
    the Authorization header and in no error text, log line or file.

An item is passed on as {"id": shown, "subject", "url"} (the strip's entry shape; the page uses nothing else), in the order stackshot sent,
each id once, none dropped and none re-sorted. An empty group is an empty list, which is an answer (the strip reads "nothing waiting").
"""

from __future__ import annotations

import asyncio
import json
import time
import urllib.error
import urllib.request
from pathlib import Path

from . import board as B
from . import swr as SWR

TTL = 30.0           # one read per 30 s, however many pages poll
ERROR_RETRY = 30.0   # after a failure, try again at the next poll
TIMEOUT = 3.0        # the read's own timeout: the page never waits on it, the background refresh does
STALE_MAX = 600.0    # the last good list stands this long (seconds) while the read keeps failing
SUBJECT_MAX = 300
SHOWN_MAX = 80


def fetch_your_move(url: str, token: str) -> object:
    """GET /client/your-move (blocking; run it in a thread). Raises board.Unauthorized on 401, RuntimeError otherwise, with a message
    that carries neither the token nor the URL."""
    req = urllib.request.Request(f"{url}/client/your-move", headers={"Authorization": f"Bearer {token}", "User-Agent": "sala-web"})
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


def parse(body: object) -> list[dict]:
    """The strip's entries of one answer, in the order sent, each id once. RuntimeError for an answer that is no list of items."""
    items = body.get("items") if isinstance(body, dict) else None
    if not isinstance(items, list):
        raise RuntimeError("stackshot sent an unexpected answer")
    out: list[dict] = []
    seen: set[str] = set()
    for it in items:
        if not isinstance(it, dict):
            continue
        shown = str(it.get("shown") or "").strip()[:SHOWN_MAX]
        if not shown or shown in seen:
            continue
        seen.add(shown)
        url = str(it.get("url") or "").strip()
        out.append({"id": shown, "subject": " ".join(str(it.get("subject") or "").split())[:SUBJECT_MAX],
                    "url": url[:500] if url.startswith(("http://", "https://", "/")) and not url.startswith("//") else ""})
    return out


class YourMoveCache:
    """The owner's Your move list, served at once from the last good answer and refreshed in the background once it is TTL old."""

    def __init__(self, token_path: Path, url_path: Path, state_path: Path | None = None, fetch=fetch_your_move):
        self.token_path = token_path
        self.url_path = url_path
        self.fetch = fetch
        self._swr = SWR.Revalidating(state_path, TTL, ERROR_RETRY, {"items": []}, valid=lambda d: isinstance(d.get("items"), list))

    def items(self) -> list[dict] | None:
        """The list now (a refresh started when one is due, never waited for): the last good answer while it is no older than STALE_MAX,
        else None (never read, or the reads have been failing for too long) and the caller uses the board feed."""
        doc = self._swr.serve(self._refresh)
        fetched = doc.get("fetchedAt")
        if not isinstance(fetched, int) or not isinstance(doc.get("items"), list):
            return None
        if time.time() - fetched / 1000 > STALE_MAX:
            return None
        return doc["items"]

    async def _refresh(self) -> dict:
        try:
            token, url = B.read_token(self.token_path), B.read_url(self.url_path)
        except B.ConfigError as e:
            raise SWR.Failed(str(e)) from None
        try:
            body = await asyncio.to_thread(self.fetch, url, token)
            return {"items": parse(body)}
        except B.Unauthorized:
            raise SWR.Failed(B.REFUSED) from None
        except RuntimeError as e:
            raise SWR.Failed(str(e)) from None
        except Exception as e:  # never str(e): an unexpected error could carry anything
            raise SWR.Failed(f"your move could not be read ({type(e).__name__})") from None
