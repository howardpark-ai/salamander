"""stackshot's For you list (no page shows it now: the items sheet it sat in was removed): what happened to the items he follows
(closed, reopened, a decision waiting, a check failed, due, a release failed), one row each, with Seen to dismiss a row and
Watch / Mute for an item. This module is the one place that knows stackshot's shapes, so a route that turns out different
changes the fake (tests/fake_stackshot.py) and one parse function here, and nothing else.

What it asks stackshot, with this machine's client token and address (the files the board items read, board.py; neither
reaches a page, a log or an error text) and the label `sala-web` (projpick.SENDER; stackshot lets that label act only on
the master box, else 403):

  GET  /client/for-you                   {generated, rows: [{id, kind, item, project, what, url, urgent, ts, when, slacked}],
                                          flags: {"board#N": "watch" | "mute"}}, newest first. `what` has no item id.
  POST /client/for-you/seen              {id: <int >= 1> | "all", sender} -> 200 {ok, seen: [ids ascending], rows: [the unseen rows
                                          now]}; 404 when the id is not on the list, one already marked seen included (treated
                                          here as "already gone", not an error); 400 bad id; "all" on an empty list: 200, seen [].
  POST /client/items/<key>/watch         {state: watch | mute | default, sender} -> 200 {ok, item: "board#N", state, flags: {the
                                          whole map}}; "default" removes the flag; 404 unknown item; 400 bad state. The key may
                                          be board%23N or the bare number.

All three are live (the POSTs too); 401 is no or an unknown token, 403 a sender other than exactly `sala-web`.
Everything read from the answers is tolerant: a missing `rows` in the seen answer is "the seen ids are gone from the list we had",
a missing `flags` keeps the
flags we had.

ForYouCache is BoardCache's way for one answer: read at most once a minute, the last good answer served at once, a failed
read keeping it with a plain-words error, and never an exception out of `get`.
"""

from __future__ import annotations

import asyncio
import re
import time
from pathlib import Path

from . import projpick as PP
from . import swr as SWR

TTL = 60.0
ERROR_RETRY = 30.0
SENDER = PP.SENDER
TIMEOUT_GET = 20.0
TIMEOUT_POST = 20.0
KINDS = ("closed", "reopened", "decision", "check_failed", "due", "release_failed")
STATES = ("watch", "mute", "default")        # what a Watch / Mute call may set (stackshot's three)
FLAG_STATES = ("watch", "mute")              # what the flags map holds: no entry is the default
ROWS_MAX = 200
WHAT_MAX = 300
SHORT_MAX = 80
REFUSED = "stackshot refused this machine's token (HTTP 401)"
ITEM_RE = re.compile(r"^board#([1-9][0-9]{0,8})$")
KEY_RE = re.compile(r"^(?:board#)?([1-9][0-9]{0,8})$")     # what the page may name an item by: "board#N" or "N"
SHOWN_RE = re.compile(r"^[A-Za-z][A-Za-z0-9-]*#[0-9]+$")


# ── what goes out ────────────────────────────────────────────────────────────
def item_key(raw: object) -> str | None:
    """"board#N" or "N" -> "board#N"; anything else None."""
    m = KEY_RE.match(raw.strip()) if isinstance(raw, str) else None
    return f"board#{m.group(1)}" if m else None


def validate_seen(body: object) -> dict | tuple[int, str]:
    if not isinstance(body, dict):
        return 400, "the body must be a JSON object"
    if set(body) - {"id"}:
        return 400, "unknown fields: " + ", ".join(sorted(set(body) - {"id"}))
    rid = body.get("id")
    if rid == "all":
        return {"id": "all", "sender": SENDER}
    if isinstance(rid, int) and not isinstance(rid, bool) and 0 < rid < 10**12:
        return {"id": rid, "sender": SENDER}
    return 400, 'id must be an entry\'s number or "all"'


def validate_watch(key: object, body: object) -> tuple[str, dict] | tuple[int, str]:
    """(the item as stackshot shows it, the body to send), or (status, message)."""
    shown = item_key(key)
    if shown is None:
        return 400, "the item must be board#<number>"
    if not isinstance(body, dict):
        return 400, "the body must be a JSON object"
    if set(body) - {"state"}:
        return 400, "unknown fields: " + ", ".join(sorted(set(body) - {"state"}))
    if body.get("state") not in STATES:
        return 400, "state must be one of " + ", ".join(STATES)
    return shown, {"state": body["state"], "sender": SENDER}


# ── what comes in ────────────────────────────────────────────────────────────
def _int(v: object) -> int | None:
    if isinstance(v, bool):
        return None
    if isinstance(v, int):
        return v
    if isinstance(v, str) and v.isdigit():
        return int(v)
    return None


def _text(v: object, n: int) -> str:
    return " ".join(str(v or "").split())[:n]


def clean_row(r: object) -> dict | None:
    """One row in the page's shape; None for one that is no row (no number, or nothing to say). The url must be http(s): the
    page links it."""
    if not isinstance(r, dict):
        return None
    rid, what = _int(r.get("id")), _text(r.get("what"), WHAT_MAX)
    if rid is None or not what:
        return None
    url = str(r.get("url") or "").strip()
    item = _text(r.get("item"), SHORT_MAX)
    ts = r.get("ts")
    return {"id": rid, "kind": _text(r.get("kind"), 20), "item": item if SHOWN_RE.match(item) else "", "project": _text(r.get("project"), SHORT_MAX),
            "what": what, "url": url[:500] if url.startswith(("http://", "https://")) else "", "urgent": r.get("urgent") is True,
            "ts": ts if isinstance(ts, (int, float)) and not isinstance(ts, bool) else None, "when": _text(r.get("when"), 40),
            "slacked": r.get("slacked") is True}


def clean_rows(raw: object) -> list[dict] | None:
    """The rows of an answer, newest first as sent; None when `raw` is no list."""
    if not isinstance(raw, list):
        return None
    return [r for r in (clean_row(x) for x in raw[:ROWS_MAX]) if r]


def clean_flags(raw: object) -> dict[str, str] | None:
    """The flags map, only entries of the form {"board#N": "watch" | "mute"}; None when `raw` is no map."""
    if not isinstance(raw, dict):
        return None
    return {k: v for k, v in raw.items() if isinstance(k, str) and ITEM_RE.match(k) and v in FLAG_STATES}


def parse_list(body: object) -> dict:
    """GET /client/for-you: {generated, rows, flags}. RuntimeError for an answer that is not the list."""
    rows = clean_rows(body.get("rows")) if isinstance(body, dict) else None
    if rows is None:
        raise RuntimeError("stackshot sent an answer that is not the For you list")
    flags = clean_flags(body.get("flags"))
    return {"generated": _text(body.get("generated"), 40), "rows": rows, "flags": flags if flags is not None else {}}


def parse_seen(body: object) -> dict:
    """POST /client/for-you/seen: {seen: [ids], rows: [...] | None}. `rows` None when the answer has none (the caller then
    drops the seen ids from the list it had)."""
    if not isinstance(body, dict):
        raise RuntimeError("stackshot sent an answer that is not a confirmation")
    seen = [i for i in (_int(x) for x in body["seen"]) if i is not None] if isinstance(body.get("seen"), list) else []
    return {"seen": seen, "rows": clean_rows(body.get("rows"))}


def parse_watch(body: object, asked: str, state: str) -> dict:
    """POST /client/items/<key>/watch: {item, state, flags | None}. The item and state default to what was asked."""
    if not isinstance(body, dict):
        raise RuntimeError("stackshot sent an answer that is not a confirmation")
    item = body.get("item") if isinstance(body.get("item"), str) and ITEM_RE.match(body["item"]) else asked
    got = body.get("state") if body.get("state") in STATES else state
    return {"item": item, "state": got, "flags": clean_flags(body.get("flags"))}


# ── the calls ────────────────────────────────────────────────────────────────
def watch_path(shown: str) -> str:
    """The route of one item's flag. "board#N" goes into the path as stackshot's other item routes take it; if stackshot
    wants the bare number instead, this is the one line to change."""
    return f"items/{shown.replace('#', '%23')}/watch"


class Calls:
    """The three calls, blocking (run them in a thread); each returns a projpick.Reply and never raises."""

    def __init__(self, token_path: Path, url_path: Path):
        self.token_path, self.url_path = token_path, url_path

    def list(self) -> PP.Reply:
        return PP._request(self.token_path, self.url_path, "GET", "for-you", None, None, TIMEOUT_GET)

    def seen(self, body: dict) -> PP.Reply:
        return PP._request(self.token_path, self.url_path, "POST", "for-you/seen", None, body, TIMEOUT_POST)

    def watch(self, shown: str, body: dict) -> PP.Reply:
        return PP._request(self.token_path, self.url_path, "POST", watch_path(shown), None, body, TIMEOUT_POST)


def sentence(rep: PP.Reply, what: str, gone: str) -> tuple[int, str]:
    """(HTTP status for the page, a plain sentence) for a call that did not give a 200. `what` is the action ("mark it seen",
    "change the flag"), `gone` the words for a 404. Stackshot's own message is added when it is one short line."""
    s = rep.status
    if s == -1:
        return 502, rep.error
    if s == 401:
        return 502, REFUSED
    if s == 0:
        return 502, rep.error or "stackshot could not be reached"
    msg = rep.error if isinstance(rep.data, dict) else ""
    extra = f" (stackshot says: {msg})" if msg and len(msg) <= 160 and "\n" not in msg else ""
    if s == 403:
        return 403, f"stackshot does not let this page {what}: it accepts that only from sala on the machine that runs the agents" + extra
    if s == 404:
        return 404, gone + extra
    if s == 400:
        return 400, f"stackshot did not accept that request to {what}" + extra
    return 502, f"stackshot answered HTTP {s}" + extra


class ForYouCache:
    """The list, served at once from the last good answer and refreshed in the background once it is TTL old; the flags ride
    on it. After a Seen or a Watch / Mute the answer is updated in place (`apply`), so the page need not wait for the next
    read. Kept in memory only: a restart reads it again (the first answer is {"pending": true} until it lands)."""

    def __init__(self, calls: Calls):
        self.calls = calls
        self._swr = SWR.Revalidating(None, TTL, ERROR_RETRY, {"rows": [], "flags": {}, "generated": ""})

    def get(self) -> dict:
        return self._swr.serve(self._refresh)

    async def _refresh(self) -> dict:
        rep = await asyncio.to_thread(self.calls.list)
        if rep.status != 200:
            if rep.status == 401:
                raise SWR.Failed(REFUSED)
            raise SWR.Failed(sentence(rep, "read the For you list", "stackshot has no For you list")[1])
        try:
            return parse_list(rep.data)
        except RuntimeError as e:
            raise SWR.Failed(str(e)) from None

    def snapshot(self) -> dict:
        """The answer now, without starting a read."""
        s = self._swr.state
        return {k: s[k] for k in ("rows", "flags", "generated", "fetchedAt") if k in s}

    def apply(self, rows: list[dict] | None = None, flags: dict | None = None, drop: list[int] | None = None) -> dict:
        """Put a POST's answer into the cached one: `rows` replace the list, else the `drop` ids leave it; `flags` replace the
        map when given. The error and the schedule of the next read stay as they were."""
        st = self._swr.state
        cur = list(st.get("rows") or [])
        if rows is not None:
            cur = rows
        elif drop:
            gone = set(drop)
            cur = [r for r in cur if r["id"] not in gone]
        st["rows"] = cur
        if flags is not None:
            st["flags"] = flags
        if st.get("fetchedAt") is None:
            st.pop("pending", None)    # an answer put in before any read: it is an answer, not a placeholder
            st["fetchedAt"] = int(time.time() * 1000)
        return self.snapshot()
