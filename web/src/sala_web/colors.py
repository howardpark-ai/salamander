"""The color tool's saved combinations: one list on the account, shared with
stackshot's page and held by stackshot, reached through this server so that the browser never carries a token or a sender.

What it asks stackshot, with this machine's client token and address (the files the board items read, board.py; neither
reaches a page, a log or an error text) and the label `sala-web` (projpick.SENDER, fixed here, never taken from the browser):

  GET  /client/colors/combos           (no body)
  POST /client/colors/combos           {name, values: {the 14 keys}, sender}  save; a name already in the list (case ignored) is replaced in place
  POST /client/colors/combos/delete    {id, sender}                           delete; an unknown id is not an error

All three answer 200 {"combos": [{id, name, values: {14 keys}, saved: <epoch>, via}], "max": 50} with Cache-Control no-store.
Errors are {"error": "<a plain sentence>", "field": "name" | "values" | "id" | "sender" | <a key> | null}: 400 a bad name, value or
key set, 401 no or a bad token (plain text), 403 not allowed (the sender, or this machine), 409 the list is full, 413 over 4 KB,
415 not JSON, 503 the file cannot be read (or a standby copy). Stackshot runs no contrast gate. The list is not cached here:
every page view asks again, so a combination saved from stackshot's page shows at once.

The 14 keys and what each moves are in static/colortool-sala.js (the pinned static/colortool.js draws the panel). A body is checked here before it is forwarded (the name's length and
characters, the 14 keys exactly, each a #rrggbb), so a wrong one is a 400 and never a request. Whatever stackshot answers goes
back as the same two fields, `error` and `field`, with a status the page can tell apart: 502 when stackshot cannot be reached or
refused this machine's token, 503 when this machine has no token or address or stackshot's file is unreadable.
"""

from __future__ import annotations

import re
import unicodedata
from pathlib import Path

from . import projpick as PP

SENDER = PP.SENDER
KEYS = ("bg", "card", "fg", "mut", "line", "ibd", "link", "solid", "onsolid", "labbg", "labfg", "labbd", "disbg", "disfg")
NAME_MAX = 40
ID_MAX = 80
SENTENCE_MAX = 200
COMBOS_MAX = 200                     # rows kept from an answer (stackshot's own cap is 50)
HEX_RE = re.compile(r"^#[0-9a-fA-F]{6}$")
TIMEOUT = 20.0
REFUSED = "stackshot refused this machine's token (HTTP 401)"


def _bad(error: str, field: str | None = None, status: int = 400) -> tuple[int, dict]:
    return status, {"error": error, "field": field}


# ── what goes out ────────────────────────────────────────────────────────────
def clean_name(raw: object) -> str | None:
    """The name as stackshot keeps it: NFC, 1 to NAME_MAX characters, no control or format character; None when it is not one.
    Surrounding blanks are cut (a name that is only blanks is empty)."""
    if not isinstance(raw, str):
        return None
    name = unicodedata.normalize("NFC", raw).strip()
    if not 1 <= len(name) <= NAME_MAX:
        return None
    if any(unicodedata.category(c) in ("Cc", "Cf") for c in name):
        return None
    return name


def clean_values(raw: object) -> dict | None:
    """The 14 keys exactly, each a #rrggbb, lowercased; None for anything else."""
    if not isinstance(raw, dict) or set(raw) != set(KEYS):
        return None
    out = {}
    for k in KEYS:
        v = raw[k]
        if not isinstance(v, str) or not HEX_RE.match(v):
            return None
        out[k] = v.lower()
    return out


def validate_save(body: object) -> dict | tuple[int, dict]:
    """The body to send stackshot, or (status, {error, field})."""
    if not isinstance(body, dict):
        return _bad("The body must be a JSON object.")
    extra = sorted(set(body) - {"name", "values"})
    if extra:
        return _bad("Unknown fields: " + ", ".join(str(x)[:40] for x in extra) + ".")
    name = clean_name(body.get("name"))
    if name is None:
        return _bad(f"The name is 1 to {NAME_MAX} characters, with no control characters.", "name")
    vals = body.get("values")
    if not isinstance(vals, dict):
        return _bad("values is the 14 colors.", "values")
    missing = [k for k in KEYS if k not in vals]
    unknown = sorted(str(k)[:20] for k in vals if k not in KEYS)
    if missing or unknown:
        return _bad("values holds exactly these 14 colors: " + ", ".join(KEYS) + ".", "values")
    for k in KEYS:
        if not isinstance(vals[k], str) or not HEX_RE.match(vals[k]):
            return _bad(f"{k} is a color written #rrggbb.", k)
    return {"name": name, "values": clean_values(vals), "sender": SENDER}


def validate_delete(body: object) -> dict | tuple[int, dict]:
    if not isinstance(body, dict):
        return _bad("The body must be a JSON object.")
    extra = sorted(set(body) - {"id"})
    if extra:
        return _bad("Unknown fields: " + ", ".join(str(x)[:40] for x in extra) + ".")
    cid = body.get("id")
    if not isinstance(cid, str) or not 1 <= len(cid) <= ID_MAX or any(unicodedata.category(c) in ("Cc", "Cf") for c in cid):
        return _bad("id is the saved combination's id.", "id")
    return {"id": cid, "sender": SENDER}


# ── the calls ────────────────────────────────────────────────────────────────
class Calls:
    """The three calls, blocking (run them in a thread); each returns a projpick.Reply and never raises."""

    def __init__(self, token_path: Path, url_path: Path):
        self.token_path, self.url_path = token_path, url_path

    def list(self) -> PP.Reply:
        return PP._request(self.token_path, self.url_path, "GET", "colors/combos", None, None, TIMEOUT)

    def save(self, body: dict) -> PP.Reply:
        return PP._request(self.token_path, self.url_path, "POST", "colors/combos", None, body, TIMEOUT)

    def delete(self, body: dict) -> PP.Reply:
        return PP._request(self.token_path, self.url_path, "POST", "colors/combos/delete", None, body, TIMEOUT)


# ── what comes in ────────────────────────────────────────────────────────────
def _one_line(text: object) -> str:
    return " ".join(str(text or "").split())[:SENTENCE_MAX]


def parse_combos(data: object) -> dict | None:
    """{"combos": [{id, name, values, saved, via}], "max": n} in the page's shape; a row that is not one is left out; None when
    the answer is not the list."""
    if not isinstance(data, dict) or not isinstance(data.get("combos"), list):
        return None
    rows = []
    for c in data["combos"][:COMBOS_MAX]:
        if not isinstance(c, dict):
            continue
        name, vals, cid = clean_name(c.get("name")), clean_values(c.get("values")), c.get("id")
        if name is None or vals is None or not isinstance(cid, str) or not cid:
            continue
        saved = c.get("saved")
        rows.append({"id": cid[:ID_MAX], "name": name, "values": vals,
                     "saved": saved if isinstance(saved, (int, float)) and not isinstance(saved, bool) else None,
                     "via": _one_line(c.get("via"))[:40]})
    mx = data.get("max")
    return {"combos": rows, "max": mx if isinstance(mx, int) and not isinstance(mx, bool) and mx > 0 else None}


def failure(rep: PP.Reply) -> tuple[int, dict]:
    """(HTTP status, {error, field}) for a call that did not give a 200. Stackshot's own sentence and field pass on for its 400, 403,
    409, 413 and 415 (the page shows the sentence); everything else is told in this server's words, the token and the address
    never in them."""
    s = rep.status
    if s == -1:
        return _bad(_one_line(rep.error) or "This machine has no stackshot setup.", None, 503)
    if s == 0:
        return _bad(_one_line(rep.error) or "stackshot could not be reached.", None, 502)
    if s == 401:
        return _bad(REFUSED, None, 502)
    d = rep.data if isinstance(rep.data, dict) else {}
    sentence = _one_line(d.get("error"))
    field = d.get("field")
    field = field if field is None or field in ("name", "values", "id", "sender", *KEYS) else None
    if s in (400, 403, 409, 413, 415):
        return s, {"error": sentence or f"stackshot answered HTTP {s}.", "field": field}
    if s == 503:
        return _bad(sentence or "stackshot cannot read its saved list right now.", None, 503)
    return _bad(f"stackshot answered HTTP {s}" + (f" ({sentence})" if sentence else "") + ".", None, 502)


def answer(rep: PP.Reply) -> tuple[int, dict]:
    """(status, body) for the page from stackshot's reply to any of the three calls: the list, or {error, field}."""
    if rep.status != 200:
        return failure(rep)
    got = parse_combos(rep.data)
    if got is None:
        return _bad("stackshot sent an answer that is not the saved list.", None, 502)
    return 200, got
