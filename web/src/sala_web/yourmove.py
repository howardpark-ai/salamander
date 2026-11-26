"""The owner's whole "Your move" group, for the chat session's Your move strip.

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

The answer also carries the group's own name, "group": {"en", "ko"}, which the page draws in the strip's words (the pinned line, its
titles, the sidebar chip) in place of its own copy, so a rename in stackshot cannot leave the old words here. `parse_group` accepts only a
dict with a string `en` and a string `ko`, each 1..40 characters once stripped, no control character and no markup; anything else, or
no `group` key (an older stackshot), is None: no group, never an error, and the page uses its own words.

An item is passed on as {"id": shown, "subject", "url"} (the strip's entry shape; the page uses nothing else), in the order stackshot sent,
each id once, none dropped and none re-sorted. An empty group is an empty list, which is an answer (the strip draws no pinned line).
"""

from __future__ import annotations

import asyncio
import json
import time
import unicodedata
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
GROUP_MAX = 40       # the longest word of the group's name taken, in characters, once stripped


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


def _group_word(v: object) -> str | None:
    """One word of the group's name: a string of 1..GROUP_MAX characters once stripped, with no control or format character (a newline, a
    zero-width mark, a bidi override: checked before the strip) and no markup (`<` or `>`); else None."""
    if not isinstance(v, str) or "<" in v or ">" in v or any(unicodedata.category(c).startswith("C") for c in v):
        return None
    v = v.strip()
    return v if 1 <= len(v) <= GROUP_MAX else None


def parse_group(body: object) -> dict | None:
    """The group's name of one answer, {"en", "ko"}, or None: no `group` (an older stackshot), or one that is not a dict with both words
    well formed. Never raises: a bad name is no name, and the list is still the answer."""
    g = body.get("group") if isinstance(body, dict) else None
    if not isinstance(g, dict):
        return None
    en, ko = _group_word(g.get("en")), _group_word(g.get("ko"))
    return {"en": en, "ko": ko} if en is not None and ko is not None else None


class YourMoveCache:
    """The owner's Your move list, served at once from the last good answer and refreshed in the background once it is TTL old."""

    def __init__(self, token_path: Path, url_path: Path, state_path: Path | None = None, fetch=fetch_your_move):
        self.token_path = token_path
        self.url_path = url_path
        self.fetch = fetch
        self._swr = SWR.Revalidating(state_path, TTL, ERROR_RETRY, {"items": []}, valid=lambda d: isinstance(d.get("items"), list))

    def _current(self) -> dict | None:
        """The last good answer while it is no older than STALE_MAX (a refresh started when one is due, never waited for), else None."""
        doc = self._swr.serve(self._refresh)
        fetched = doc.get("fetchedAt")
        if not isinstance(fetched, int) or not isinstance(doc.get("items"), list):
            return None
        if time.time() - fetched / 1000 > STALE_MAX:
            return None
        return doc

    def items(self) -> list[dict] | None:
        """The list now (a refresh started when one is due, never waited for): the last good answer while it is no older than STALE_MAX,
        else None (never read, or the reads have been failing for too long) and the caller uses the board feed."""
        doc = self._current()
        return None if doc is None else doc["items"]

    def group(self) -> dict | None:
        """The group's name {"en", "ko"} of the answer `items()` serves, or None (an older stackshot sent none, or a bad one, or there is no
        answer): the page then uses its own words."""
        doc = self._current()
        g = None if doc is None else doc.get("group")
        ok = isinstance(g, dict) and _group_word(g.get("en")) is not None and _group_word(g.get("ko")) is not None   # a saved file is read again, not trusted
        return {"en": g["en"], "ko": g["ko"]} if ok else None

    async def _refresh(self) -> dict:
        try:
            token, url = B.read_token(self.token_path), B.read_url(self.url_path)
        except B.ConfigError as e:
            raise SWR.Failed(str(e)) from None
        try:
            body = await asyncio.to_thread(self.fetch, url, token)
            return {"items": parse(body), "group": parse_group(body)}
        except B.Unauthorized:
            raise SWR.Failed(B.REFUSED) from None
        except RuntimeError as e:
            raise SWR.Failed(str(e)) from None
        except Exception as e:  # never str(e): an unexpected error could carry anything
            raise SWR.Failed(f"your move could not be read ({type(e).__name__})") from None
