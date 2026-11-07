"""Each live session's open board items, read from stackshot's client API (the page's one reader of them is the
New session page's board item picker; the title bar's item count button, the items sheet and the Agents table's count
that used to show them were removed).

One read, GET <server>/client/items?key=<session name> with this machine's token as a bearer, scans the whole board
store on the server, so the answers are cached here (swr.py): one refresh per TTL for every live session, at most
CONCURRENCY reads at a time, served at once from the last good answer and kept under the state dir as text only (ids,
subjects, needs, urls; never the token). A page view never causes a request of its own.

"Waiting on the owner" is an item whose needs lists "decision" and which is not held: stackshot parks a held item (on
hold, or after another item) out of his queue ("an item waiting on him is never held", its server.py). "external" in
needs is waiting on someone else, not him. Since stackshot's one rule for an item that waits each
item also carries its mover {kind: session | owner (an older spelling) | outside, who, via?}, the kind of wait, expected_by (epoch
seconds), overdue and step; they pass through as they come (they make a row's detail line), and with them "waiting on
the owner" is mover.kind "owner" (or an older spelling) with no `via` (an item that waits after another is in his queue under that one, not
twice); that `waiting` only tags a row. An older stackshot sends none of them: the rule above stands.

Which of stackshot's three lists an item is in ("Your move", "Agents at work", "Waiting") is decided by two more fields
that pass through as they come: `state` (stackshot's per-row state: doing, queued, your-call, your-step, outside, blocked,
parked, verifying) and, once stackshot sends it, `list` (your-move | agents | waiting). The page no longer sorts them.

The token is read from its file at each refresh and only ever sent as the Authorization header: never logged, never
put in an error string, a response or the state file. HTTP errors carry only their status code.
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from . import swr as SWR

TTL = 60.0           # one round of reads per minute, however many pages poll
ERROR_RETRY = 30.0   # after a failure, try again before the page's next poll (every 60 s)
CONCURRENCY = 4      # reads in flight at once against the board server
REFUSED = "stackshot refused this machine's token (HTTP 401)"
SUBJECT_MAX = 300
WHO_MAX = 200
STATE_MAX = 40
LISTS = ("your-move", "agents", "waiting")   # stackshot's home page lists (home.list_of), in its order
WAIT_KINDS = ("after", "failed", "hold", "wake", "recycle", "due", "check", "needs", "end", "idle")   # "end": a verifying item's end date
_SHOWN_RE = re.compile(r"^([A-Za-z][A-Za-z0-9-]*)#(\d+)$")


class ConfigError(Exception):
    """A plain message for the page (never carries a secret)."""


class Unauthorized(Exception):
    pass


def read_token(path: Path) -> str:
    try:
        token = path.read_text().strip()
    except FileNotFoundError:
        raise ConfigError("No stackshot token on this machine.") from None
    except OSError:
        raise ConfigError("The stackshot token file could not be read.") from None
    if not token:
        raise ConfigError("The stackshot token file is empty.")
    return token


def read_url(path: Path) -> str:
    """The board server's address: STACKSHOT_URL in the environment (stackshot's own override), else the file."""
    url = os.environ.get("STACKSHOT_URL", "").strip()
    if not url:
        try:
            url = path.read_text().strip()
        except OSError:
            raise ConfigError("No stackshot server address on this machine.") from None
    if not url.startswith(("http://", "https://")):
        raise ConfigError("The stackshot server address is not a URL.")
    return url.rstrip("/")


def fetch_items(url: str, token: str, key: str) -> dict:
    """GET /client/items?key=<session> (blocking; run it in a thread). Raises Unauthorized on 401, RuntimeError
    otherwise, with a message that carries neither the token nor the URL."""
    req = urllib.request.Request(f"{url}/client/items?{urllib.parse.urlencode({'key': key})}",
                                 headers={"Authorization": f"Bearer {token}", "User-Agent": "sala-web"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        if e.code == 401:
            raise Unauthorized() from None
        raise RuntimeError(f"stackshot answered HTTP {e.code}") from None
    except urllib.error.URLError as e:  # the reason names the network fault (refused, reset, a timeout); no token or URL in it
        raise RuntimeError(f"stackshot unreachable ({str(e.reason)[:80]})") from None
    except (TimeoutError, OSError) as e:
        raise RuntimeError(f"stackshot unreachable ({type(e).__name__})") from None
    except ValueError:
        raise RuntimeError("stackshot sent an unreadable answer") from None


def item_href(shown: str) -> str:
    """The id in an item's page address, as stackshot's ghsync.href_id writes it: "board#N" → "N" (its page is
    /items/N), a temporary "board-tmp-box#N" → "board-tmp-box-N", an older "sN" → "sN"."""
    m = _SHOWN_RE.match(shown)
    if not m:
        return shown
    prefix, n = m.groups()
    return n if prefix == "board" else f"{prefix}-{n}"


def item_url(web_base: str, shown: str) -> str:
    """The item's page address under the board's web address; "" when none is set (the item then carries no link)."""
    if not web_base.strip():
        return ""
    return f"{web_base.rstrip('/')}/items/{urllib.parse.quote(item_href(shown), safe='')}"


OWNER_KINDS = frozenset({"owner"})              # mover.kind that means the owner
OWNER_NEEDS = frozenset({"decision", "owner"})  # needs values that put an item in the owner's queue
MOVER_KINDS = frozenset({"session", "outside"}) | OWNER_KINDS


def waits_on_owner(needs: list[str], held: bool) -> bool:
    return not held and any(n.strip().lower() in OWNER_NEEDS for n in needs)


def waits_on_owner_by_mover(mover: dict) -> bool:
    """With stackshot's mover: it is the owner's move itself, not one he is reached through (`via`: waiting after an item)."""
    return mover.get("kind") in OWNER_KINDS and not mover.get("via")


def wait_fields(it: dict) -> dict:
    """The one rule's fields of an item, as stackshot's client API sends them, cleaned: mover {kind, who, via?}, wait (one
    of WAIT_KINDS), expected_by (epoch seconds), overdue, step. A field that is absent or malformed is left out, so an older
    stackshot's answer gives the page nothing new and it falls back to `held`."""
    out: dict = {}
    mv = it.get("mover")
    if isinstance(mv, dict) and mv.get("kind") in MOVER_KINDS:
        m = {"kind": mv["kind"], "who": str(mv.get("who") or "").strip()[:WHO_MAX]}
        if mv.get("via"):
            m["via"] = str(mv["via"]).strip()[:WHO_MAX]
        out["mover"] = m
    if it.get("wait") in WAIT_KINDS:
        out["wait"] = it["wait"]
    eb = it.get("expected_by")
    if isinstance(eb, (int, float)) and not isinstance(eb, bool) and eb > 0:
        out["expected_by"] = int(eb)
    if isinstance(it.get("overdue"), bool):
        out["overdue"] = it["overdue"]
    step = it.get("step")
    if isinstance(step, int) and not isinstance(step, bool) and step >= 0:
        out["step"] = step
    return out


def list_fields(it: dict) -> dict:
    """The row's `state` (doing, queued, your-call, your-step, outside, blocked, parked, verifying; passed on as a short
    string, the page decides what an unknown one means) and, once stackshot sends it, its `list` (one of LISTS): the page
    groups the items by them. An absent or malformed one is left out, so the page falls back to `state`, then
    to Waiting."""
    out: dict = {}
    st = it.get("state")
    if isinstance(st, str) and st.strip():
        out["state"] = st.strip()[:STATE_MAX]
    if it.get("list") in LISTS:
        out["list"] = it["list"]
    return out


def parse_items(body: object, web_base: str) -> list[dict]:
    """The items of one session's answer, in the page's shape: waiting ones first, then the rest, held ones last (the page
    groups them by `state` or `list`)."""
    items = body.get("items") if isinstance(body, dict) else None
    if not isinstance(items, list):
        raise RuntimeError("stackshot sent an unexpected answer")
    out = []
    for it in items:
        if not isinstance(it, dict):
            continue
        shown = str(it.get("shown") or it.get("gid") or "").strip()
        if not shown:
            continue
        raw = it.get("needs")
        needs = [n for n in raw if isinstance(n, str)] if isinstance(raw, list) else []
        held = bool(it.get("held"))
        fields = {**wait_fields(it), **list_fields(it)}
        waiting = waits_on_owner_by_mover(fields["mover"]) if "mover" in fields else waits_on_owner(needs, held)
        out.append({"id": shown, "subject": str(it.get("subject") or "").strip()[:SUBJECT_MAX], "needs": needs,
                    "waiting": waiting, "held": held, "url": item_url(web_base, shown), **fields})
    out.sort(key=lambda i: (i["held"], not i["waiting"]))  # a stable sort: the server's order within each group
    return out


def session_entry(items: list[dict]) -> dict:
    return {"items": items, "waiting": sum(1 for i in items if i["waiting"])}


class BoardCache:
    """Every live session's items, served at once from the last good answer (kept in memory and in a file under the
    state dir, so a restart has it too) and refreshed in the background once it is TTL old: however many pages poll,
    the board is asked one round per TTL, CONCURRENCY sessions at a time. A session whose read fails keeps its last
    answer while the others are refreshed; a round in which nothing could be read keeps everything, adds an error and
    is retried ERROR_RETRY later. The file holds the items as text (ids, subjects, needs, urls), never the token."""

    def __init__(self, token_path: Path, url_path: Path, web_base: str, state_path: Path | None = None,
                 fetch=fetch_items, concurrency: int = CONCURRENCY):
        self.token_path = token_path
        self.url_path = url_path
        self.web_base = web_base
        self.fetch = fetch
        self.concurrency = max(1, concurrency)
        self._swr = SWR.Revalidating(state_path, TTL, ERROR_RETRY, {"sessions": {}},
                                     valid=lambda d: isinstance(d.get("sessions"), dict))

    async def get(self, names: list[str]) -> dict:
        names = list(dict.fromkeys(n for n in names if isinstance(n, str) and n))
        return self._swr.serve(lambda: self._refresh(names))

    async def _refresh(self, names: list[str]) -> dict:
        try:
            token, url = read_token(self.token_path), read_url(self.url_path)
        except ConfigError as e:
            raise SWR.Failed(str(e)) from None
        sem = asyncio.Semaphore(self.concurrency)

        async def one(name: str) -> tuple[str, list[dict] | None, str | None]:
            async with sem:
                try:
                    return name, parse_items(await asyncio.to_thread(self.fetch, url, token, name), self.web_base), None
                except Unauthorized:
                    return name, None, REFUSED
                except RuntimeError as e:
                    return name, None, str(e)
                except Exception as e:  # never str(e): an unexpected error could carry anything
                    return name, None, f"board could not be read ({type(e).__name__})"

        results = await asyncio.gather(*(one(n) for n in names))
        prev = self._swr.state.get("sessions") or {}
        sessions: dict[str, dict] = {}
        errors: list[str] = []
        for name, items, err in results:
            if items is None:
                errors.append(err or "board could not be read")
                if name in prev:
                    sessions[name] = prev[name]  # the last answer stands for a session whose read failed
            else:
                sessions[name] = session_entry(items)
        if REFUSED in errors:
            raise SWR.Failed(REFUSED)
        if errors and len(errors) == len(results):
            raise SWR.Failed(errors[0])
        out: dict = {"sessions": sessions}
        if errors:
            out["partial"] = len(errors)  # how many sessions kept their earlier answer this round
        return out
