"""A lane's record, read-only (salamander lib/common.sh, "THE LANE FIELDS", the details page).

sala keeps one row of fields per lane (provider, client, org, billing, plan, account, how it signs in, region, …), the
table `sala lane --json` prints (`lane_fields_tsv`, in the order of SALA_LANE_FIELDS). This module runs that command and
shapes one lane's row for the lane's details page; nothing here writes anything, and nothing is cached: the page asks when
it opens and about once a minute after.

What it leaves out on purpose: a file path. The table's `credential` field says how a lane signs in, and for the API lane
that is "key file ~/… + workspace id file ~/…"; the words are kept and the paths are taken out ("key file + workspace id
file"), in every field, so no key or sign-in file's location leaves the server. No secret is read here: the table holds
labels and an account email, never a token.
"""

from __future__ import annotations

import json
import re

from . import lanestate as LS

TIMEOUT = 15.0
LANE_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")
# the fields the page shows, in the order of SALA_LANE_FIELDS; `status` is the table's own word (active, inactive, not set
# up), which the page does not show: the lane's state is lane-state.tsv's, with "not set up" from the table
FIELDS = ("id", "label", "provider", "client", "org", "project", "billing", "payment", "plan", "account", "credential",
          "region", "status")
VALUE_MAX = 200
_PATH = re.compile(r"""(?<![\w@])(?:~|\.{0,2}/)[^\s,;+)"']*|\b[A-Za-z]:\\[^\s,;+)"']*""")
_CTRL = re.compile(r"[\x00-\x1f\x7f]")


def plain(value: object) -> str:
    """A field's text with every file path taken out and the spaces tidied; one line, at most VALUE_MAX characters."""
    if not isinstance(value, str):
        return ""
    v = _CTRL.sub(" ", value)
    v = _PATH.sub("", v)
    v = re.sub(r"\s+", " ", v)
    v = re.sub(r"\s+([+,;])", r" \1", v).strip(" +,;")   # "key file + workspace id file" keeps its plus; a dangling one goes
    return v[:VALUE_MAX]


def parse_table(stdout: str) -> list[dict]:
    """The lane rows out of `sala lane --json`'s output ({"lanes": [{…}]}); a ValueError when it is no such document."""
    start = stdout.find("{")
    if start < 0:
        raise ValueError("no JSON in the lane table")
    doc, _ = json.JSONDecoder().raw_decode(stdout[start:])
    lanes = doc.get("lanes") if isinstance(doc, dict) else None
    if not isinstance(lanes, list):
        raise ValueError("the lane table has no lanes")
    return [r for r in lanes if isinstance(r, dict)]


def default_of(stdout: str) -> str:
    """The lane a session with no lane of its own launches on: the table's `default` (sala lane default); "" when the output is
    no such document or names no lane. The New session form prints it beside "use default"."""
    try:
        start = stdout.find("{")
        doc, _ = json.JSONDecoder().raw_decode(stdout[start:]) if start >= 0 else ({}, 0)
    except ValueError:
        return ""
    d = doc.get("default") if isinstance(doc, dict) else None
    return LS.renamed(d) if isinstance(d, str) and LANE_ID_RE.match(d) else ""


def record_of(rows: list[dict], lane: str) -> dict | None:
    """One lane's record (the fields in FIELDS, every value plain text, "" for a field the table leaves out), or None
    when the table has no such lane. sdk is the api lane's word and an old name is the new one (lanestate.ALIASES); the table's own id is read the same way."""
    want = LS.norm(lane)
    for r in rows:
        if LS.norm(r.get("id")) == want:
            return {f: (want if f == "id" else plain(r.get(f))) for f in FIELDS}   # the id says the code, whichever word the table used
    return None


def state_of(record: dict | None, dormant: dict | None) -> dict:
    """The lane's state for the page: dormant (lane-state.tsv, with its reason and since), else "not set up" when the
    table says so, else active; "unknown" when the table could not be read and the record says nothing."""
    if dormant:
        return {"state": "dormant", "reason": str(dormant.get("reason") or ""), "since": str(dormant.get("since") or "")}
    if record is None:
        return {"state": "unknown"}
    if record["status"] == "not set up":
        return {"state": "not set up"}
    return {"state": "active"}
