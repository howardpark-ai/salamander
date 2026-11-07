"""The Overview's Machines tab (GET /api/machines): every machine with the versions it runs and how it stays current, read from
files other programs write. Nothing is asked of GitHub, ssh or a machine, and nothing is written: the tab shows the last reading,
with its age.

Sources (all read-only; a missing or unreadable one makes the tab say "no reading yet", never an error):

  site/versions.json              <stackshot state>/site/versions.json: the packages (name, installed, latest, state, machines,
                                  machine_state) and the machines read over ssh (ssh_hosts). The card rows come from it.
  clients/fleet/<letter>/machine.json   <stackshot state>/clients/fleet/<letter>/machine.json: the fleet machine's name, its last setup
                                  run (setup) and update attempts (updates). A failed one is a line inside its card.
  fleet-names.tsv                 stackshot.toml [paths] fleet_names: os hostname, fleet name, board letter, tab-separated.
  stackshot.toml                  [fleet] publisher_letter (the machine that runs stackshot), [machines_panel] ssh_hosts (machines with
                                  no fleet letter), [paths] state / fleet_names; the Settings fields name where each file is (config.py).
  machine-follow/machines.toml    the machines that follow the coordinator (run_on; one [machines.<host>] table each).
  machine-follow/<host>.json      when each one last followed (at_epoch), written by machine-follow.

The order and the merge are stackshot's own, written again from its code so that the two pages agree and no machine is named here:

  order    the publisher, then the other fleet machines by letter, then the ssh hosts that are not fleet machines, in the
           order stackshot.toml lists them (stackshot fleet.machines_order).
  rows     a package row per package, in the order versions.json lists them. A fleet machine takes its row from versions.json's
           per-machine versions; a machine that is also an ssh host takes the ssh row while the host answers (the host is read live)
           and the fleet's row once it does not (stackshot render.py fleet_card). A package with no per-machine versions shows
           under the publisher only.
  alerts   a failed setup run, and every package whose latest update attempt failed, become a line in the card and mark it
           (stackshot render.py machine_alerts).
  follow   the card's last line, from data: the coordinator "the machine the others follow", a machine listed in machines.toml "follows
           <run_on> · last HH:MM" (its record's at_epoch, in the SALA_TZ zone), any other "updates itself".

The answer carries text only: no token, key or file path, and a failure reason has a NAME=value secret starred (schedules.redact).
"""

from __future__ import annotations

import json
import os
import re
import tomllib
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from . import schedules as SCH
from . import tz as TZ
from . import config as C
from .config import Settings

MAX_BYTES = 4 * 1024 * 1024        # a state file bigger than this is not read (the snapshot is a few KB)
ROW_STATES = ("latest", "update", "offline", "unknown")
NAME_MAX = 80
TEXT_MAX = 300
UNKNOWN_FOLLOW = "update source not read"   # machine-follow's list could not be read: nobody can say how the machine stays current
PUBLISHER_FOLLOW = "the machine the others follow"
SELF_FOLLOW = "updates itself"


# ---- reading ---------------------------------------------------------------------------------------------------------

def _json(path: Path | None) -> Any:
    """A JSON file's content; None when the path is none, the file is missing, too big or not JSON."""
    if path is None:
        return None
    try:
        if path.stat().st_size > MAX_BYTES:
            return None
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _mtime(path: Path) -> float | None:
    try:
        return path.stat().st_mtime
    except OSError:
        return None


def _toml(path: Path | None) -> dict | None:
    if path is None:
        return None
    try:
        with open(path, "rb") as f:
            d = tomllib.load(f)
        return d if isinstance(d, dict) else None
    except (OSError, ValueError):
        return None


def _text(v: Any, limit: int = NAME_MAX) -> str:
    """A value as one short line of text (whitespace folded, cut at `limit`); "" for none or anything that is no scalar."""
    if isinstance(v, bool) or not isinstance(v, (str, int, float)):
        return ""
    return " ".join(str(v).split())[:limit]


def _num(v: Any) -> float | None:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) and v == v and abs(v) != float("inf") else None


# ---- times -----------------------------------------------------------------------------------------------------------

def ago(seconds: float) -> str:
    s = max(0, int(seconds))
    if s < 60:
        return "just now"
    m = s // 60
    return f"{m}m ago" if m < 60 else f"{m // 60}h ago" if m < 48 * 60 else f"{m // 1440}d ago"


def clock(epoch: float) -> str:
    """HH:MM in the SALA_TZ zone (local time when unset)."""
    return datetime.fromtimestamp(epoch, tz=timezone.utc).astimezone(TZ.zone()).strftime("%H:%M")


def full_time(epoch: float) -> str:
    """"Wed Nov 4th 15:43 UTC": the date form used in prose, the zone's own label."""
    d = datetime.fromtimestamp(epoch, tz=timezone.utc).astimezone(TZ.zone())
    return f"{d.strftime('%a %b')} {SCH.ordinal(d.day)} {d.strftime('%H:%M')} {d.tzname() or ''}".rstrip()


def _fact_epoch(v: Any) -> float | None:
    """A reported time (an ISO string, Z or offset, or an epoch) as an epoch; None when unreadable."""
    n = _num(v)
    if n is not None:
        return n
    try:
        t = datetime.fromisoformat(str(v).strip().replace("Z", "+00:00"))
        return (t if t.tzinfo else t.replace(tzinfo=timezone.utc)).timestamp()
    except ValueError:
        return None


# ---- which machines, in which order (stackshot fleet.py) -------------------------------------------------------------

def fleet_names(s: Settings) -> dict[str, str]:
    """letter -> fleet name: the names file first, then the fleet state's own `fleet` name of each letter that has one."""
    out: dict[str, str] = {}
    if s.fleet_names_file is not None:
        try:
            with open(s.fleet_names_file, encoding="utf-8") as f:
                for ln in f:
                    c = ln.rstrip("\n").split("\t")
                    if ln.strip() and not ln.startswith("#") and len(c) >= 3:
                        out[c[2].strip()] = c[1].strip()
        except (OSError, UnicodeDecodeError):
            pass
    fleet_dir = s.stackshot_state / "clients" / "fleet"
    try:
        letters = sorted(p.name for p in fleet_dir.iterdir() if p.is_dir() and len(p.name) == 1)
    except OSError:
        letters = []
    for letter in letters:
        d = _json(fleet_dir / letter / "machine.json")
        n = _text(d.get("fleet")) if isinstance(d, dict) else ""
        if n:
            out[letter] = n
    return out


def ssh_host_names(toml: dict) -> list[str]:
    cfg = (toml.get("machines_panel") or {}).get("ssh_hosts") or []
    if isinstance(cfg, str):
        cfg = [cfg]
    out: list[str] = []
    for h in cfg if isinstance(cfg, list) else []:
        h = _text(h)
        if h and h not in out:
            out.append(h)
    return out


def machines_order(fleet: dict[str, str], hosts: list[str], publisher: str) -> list[tuple[str, str]]:
    """(name, letter) per machine in the panel's order; the letter is "" for an ssh host that is not a fleet machine."""
    out: list[tuple[str, str]] = []
    seen: set[str] = set()
    for letter in [publisher] + sorted(x for x in fleet if x != publisher):
        n = fleet.get(letter, letter)
        if n not in seen:
            seen.add(n)
            out.append((n, letter))
    for h in hosts:
        if h not in seen:
            seen.add(h)
            out.append((h, ""))
    return out


# ---- the machine cards (stackshot render.py fleet_card, machine_alerts) ----------------------------------------------

def _behind(installed: str, latest: Any) -> bool:
    """True when the installed version is older than the latest (numeric compare; anything unreadable is False)."""
    try:
        return bool(latest) and tuple(int(x) for x in installed.split(".")) < tuple(int(x) for x in str(latest).split("."))
    except ValueError:
        return False


def _row(package: str, version: str, state: str, latest: Any) -> dict:
    state = state if state in ROW_STATES else "unknown"
    lat = _text(latest)
    word = {"latest": "latest ✓", "offline": "offline", "unknown": "latest unknown",
            "update": "" if lat in ("", "?") else "→ " + lat}[state]
    return {"package": package, "version": version, "state": state, "text": word}


def _packages(doc: dict) -> list[dict]:
    return [p for p in (doc.get("packages") if isinstance(doc.get("packages"), list) else []) if isinstance(p, dict) and _text(p.get("name"))]


def fleet_rows(letter: str, publisher: str, packages: list[dict]) -> dict[str, dict]:
    """The package rows of fleet machine `letter`, keyed by package: only the packages that run there."""
    out: dict[str, dict] = {}
    for p in packages:
        name = _text(p["name"])
        if isinstance(p.get("machines"), dict):
            inst = _text((p["machines"]).get(letter))
            if not inst:
                continue
            ms = p.get("machine_state") if isinstance(p.get("machine_state"), dict) else {}
            state = "offline" if _text(ms.get(letter)).startswith("offline") else ("update" if _behind(inst, p.get("latest")) else "latest")
        else:
            if letter != publisher:
                continue                                 # a package of the publisher alone
            inst, state = _text(p.get("installed")), _text(p.get("state"))
        out[name] = _row(name, inst, state, p.get("latest"))
    return out


def host_rows(host: dict, packages: list[dict]) -> dict[str, dict]:
    """The package rows of an ssh-read host. An unreachable host shows the versions it last had as offline, or one `offline` row (package "")."""
    pk = host.get("packages") if isinstance(host.get("packages"), dict) else {}
    up = host.get("reachable") is not False
    out: dict[str, dict] = {}
    for p in packages:
        name = _text(p["name"])
        inst = _text(pk.get(name))
        if not inst:
            continue
        latest = p.get("latest")
        latest = latest if latest and latest != "?" else ""
        state = "offline" if not up else ("update" if _behind(inst, latest) else ("latest" if latest else "unknown"))
        out[name] = _row(name, inst, state, latest)
    if not out and not up:
        out[""] = _row("", "", "offline", "")
    return out


def card_rows(letter: str, publisher: str, host: dict | None, packages: list[dict]) -> list[dict]:
    """One machine's rows. Without an ssh host: the fleet's. With one (the same machine): per package the ssh row while the host
    answers, else the fleet's row (the host's last-known row only for a package the fleet does not know); the host's lone `offline`
    row only when neither has a package."""
    f = fleet_rows(letter, publisher, packages) if letter else {}
    if host is None:
        return list(f.values())
    p = host_rows(host, packages)
    up = host.get("reachable") is not False
    names = [_text(x["name"]) for x in packages]
    merged = [((p.get(n) or f[n]) if up else (f.get(n) or p[n])) for n in names if n in p or n in f]
    return merged or list(p.values())


def machine_alerts(m: dict) -> tuple[dict | None, list[dict]]:
    """A machine view's last setup run when it failed, and each package's latest update attempt when it failed (the last one listed
    for a package wins; an absent or malformed list is none)."""
    s = m.get("setup") if isinstance(m.get("setup"), dict) else None
    latest: dict[str, dict] = {}
    for u in m.get("updates") if isinstance(m.get("updates"), list) else []:
        if isinstance(u, dict) and _text(u.get("what")):
            latest[_text(u["what"])] = u
    return (s if s and s.get("ok") is False else None), [u for u in latest.values() if u.get("ok") is False]


def _when_tip(v: Any, now: float) -> str:
    t = _fact_epoch(v)
    return f"{ago(now - t)} ({full_time(t)})" if t is not None else "at an unknown time"


def _reason(v: Any) -> str:
    return SCH.redact(_text(v, TEXT_MAX)) or "no reason given"


def card_alerts(m: dict, now: float) -> list[dict]:
    """The failure lines of a card: {kind: setup | update, detail, tip}; the tip carries the reason, the line a few words."""
    setup, updates = machine_alerts(m)
    out: list[dict] = []
    if setup:
        step = _text(setup.get("step")) or "?"
        out.append({"kind": "setup", "detail": f"step {step}",
                    "tip": f"setup failed at step {step} {_when_tip(setup.get('at'), now)}: {_reason(setup.get('reason'))}"})
    for u in updates:
        ver = " → ".join(x for x in (_text(u.get("from")), _text(u.get("to"))) if x)
        what = _text(u.get("what"))
        out.append({"kind": "update", "detail": " ".join(x for x in (what, _text(u.get("to"))) if x),
                    "tip": f"{what} update{' ' + ver if ver else ''} failed {_when_tip(u.get('at'), now)}: {_reason(u.get('reason'))}"})
    return out


def follow_line(name: str, publisher_name: str, follow: dict | None, state_dir: Path) -> dict:
    """How the machine stays current: {kind: publisher | follows | self | unknown, text, tip}. `follow` is machines.toml as read (None: not readable)."""
    run_on = _text(follow.get("run_on")) if follow else ""
    machines = follow.get("machines") if follow and isinstance(follow.get("machines"), dict) else {}
    entry = machines.get(name) if isinstance(machines.get(name), dict) else None
    if name == publisher_name or (run_on and name == run_on) or (entry and _text(entry.get("run_on")) == name):
        return {"kind": "publisher", "text": PUBLISHER_FOLLOW, "tip": ""}
    if follow is None:
        return {"kind": "unknown", "text": UNKNOWN_FOLLOW, "tip": "the list of machines that follow the coordinator could not be read"}
    if entry is None:
        return {"kind": "self", "text": SELF_FOLLOW, "tip": ""}
    source = run_on or publisher_name or "the coordinator"
    rec = _json(state_dir / f"{name}.json") if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name) else None
    at = _num(rec.get("at_epoch")) if isinstance(rec, dict) else None
    if at:
        return {"kind": "follows", "text": f"follows {source} · last {clock(at)}", "tip": f"last followed {full_time(at)}"}
    return {"kind": "follows", "text": f"follows {source}", "tip": "no record of a follow yet"}


def machines_section(s: Settings, toml: dict, now: float, order: list[tuple[str, str]], publisher: str, publisher_name: str) -> dict:
    doc = _json(s.stackshot_state / "site" / "versions.json")
    if not isinstance(doc, dict):
        return {"ok": False, "reason": "stackshot has not written the machines' versions yet", "ts": None, "cards": []}
    packages = _packages(doc)
    hosts: dict[str, dict] = {}
    for h in doc.get("ssh_hosts") if isinstance(doc.get("ssh_hosts"), list) else []:
        if isinstance(h, dict) and _text(h.get("name")):
            hosts.setdefault(_text(h["name"]), h)
    follow = _toml(s.follow_machines_file)
    cards = []
    for name, letter in order:
        m = _json(s.stackshot_state / "clients" / "fleet" / letter / "machine.json") if letter else None
        alerts = card_alerts(m, now) if isinstance(m, dict) else []
        cards.append({"name": name, "alert": bool(alerts), "rows": card_rows(letter, publisher, hosts.get(name), packages),
                      "alerts": alerts, "follow": follow_line(name, publisher_name, follow, s.follow_state_dir)})
    return {"ok": True, "reason": "", "ts": _mtime(s.stackshot_state / "site" / "versions.json"), "cards": cards}


# ---- the answer ------------------------------------------------------------------------------------------------------

def collect(s: Settings, toml: dict | None = None, now: float | None = None) -> dict:
    """The whole answer. `toml` is stackshot's settings file as a dict (read now when not given); `now` the moment it is for."""
    if toml is None:
        toml = C._stackshot_toml()
    now = datetime.now(timezone.utc).timestamp() if now is None else now
    publisher = _text((toml.get("fleet") or {}).get("publisher_letter")) or "a"
    fleet = fleet_names(s)
    order = machines_order(fleet, ssh_host_names(toml), publisher)
    machines = machines_section(s, toml, now, order, publisher, fleet.get(publisher, ""))
    return {"generated": now, "tzLabel": TZ.label(), "updated": machines.get("ts"), "machines": machines}   # the footer's reading: the versions file's time
