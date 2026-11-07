"""The zone every time the web UI shows is in: sala's setting SALA_TZ (an IANA name such as Europe/Berlin), read the way sala
reads it (the environment, else sala's config file; see config.sala_setting). Unset or empty is this machine's own local time,
and the browser then shows the viewer's. A name that is not a zone is the same as unset. The label ("IST", "CEST", "UTC") is
the zone's own abbreviation for the moment shown, never a literal."""

from __future__ import annotations

import os
from datetime import datetime, timezone, tzinfo
from pathlib import Path
from zoneinfo import ZoneInfo

from .config import sala_setting


_seen: dict = {"key": None, "value": ""}


def _config_path() -> str:
    return os.environ.get("SALA_CONFIG") or str(Path.home() / ".config" / "salamander" / "config")


def setting() -> str:
    """SALA_TZ as set: the zone's name, or "" for local time. A name zoneinfo does not know gives "". Read on each call, but the
    config file is parsed again only when it changed (its modification time and size) or the environment's value did, because
    every timestamp on a page asks."""
    path = _config_path()
    try:
        st = os.stat(path)
        stamp = (st.st_mtime_ns, st.st_size)
    except OSError:
        stamp = None
    key = (os.environ.get("SALA_TZ"), path, stamp)
    if _seen["key"] == key:
        return _seen["value"]
    name = sala_setting("SALA_TZ").strip()
    if name:
        try:
            ZoneInfo(name)
        except Exception:
            name = ""
    _seen["key"], _seen["value"] = key, name
    return name


def _local() -> tzinfo:
    """This machine's zone: $TZ, else the zone /etc/localtime points at, else its present offset (no daylight rule)."""
    cand = os.environ.get("TZ", "").lstrip(":")
    if cand:
        try:
            return ZoneInfo(cand)
        except Exception:
            pass
    try:
        target = os.path.realpath("/etc/localtime")
        if "zoneinfo/" in target:
            return ZoneInfo(target.split("zoneinfo/", 1)[1])
    except Exception:
        pass
    return datetime.now().astimezone().tzinfo or timezone.utc


def zone() -> tzinfo:
    name = setting()
    return ZoneInfo(name) if name else _local()


def convert(dt: datetime) -> datetime:
    """An aware datetime in the zone; a naive one is taken as UTC."""
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(zone())


def now() -> datetime:
    return datetime.now(timezone.utc).astimezone(zone())


def label(dt: datetime | None = None) -> str:
    """The zone's abbreviation at `dt` (default: now), as the zone writes it: Asia/Kolkata "IST", Etc/UTC "UTC"."""
    d = convert(dt) if dt is not None else now()
    return d.tzname() or ""


def offset_min(dt: datetime | None = None) -> int:
    d = convert(dt) if dt is not None else now()
    off = d.utcoffset()
    return int(off.total_seconds() // 60) if off is not None else 0


def info() -> dict:
    """What the web UI is told (GET /api/config): the setting ("" = the viewer's own zone), the label and the UTC offset in
    minutes now, so the page can name the zone as the server does."""
    return {"timezone": setting(), "tzLabel": label(), "tzOffsetMin": offset_min()}
