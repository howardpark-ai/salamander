"""The scopes a fleet's sessions and projects are grouped by (a session is named <scope>-<project>...).

Nothing about them is built in. They come from, in this order:
  1. sala's settings SALA_SCOPES (space-separated) and SALA_DEFAULT_SCOPE, read the way every sala setting is read here
     (environment, else the line in sala's config file). A set SALA_SCOPES is the whole answer: the list, its order and
     the default are the owner's, and stackshot's file is not looked at;
  2. only when SALA_SCOPES is unset: stackshot's own settings file on this box,
     $XDG_CONFIG_HOME/stackshot/stackshot.toml, `[project_scopes]` `order` (and `default`): the same list stackshot hands
     out, read from the file it already keeps here, no request;
  3. nothing: an empty list. The sidebar then has no scope groups beyond "other" and the New session form accepts any
     scope-shaped name.
"""

from __future__ import annotations

import os
import re
from pathlib import Path

from . import config as C

_SLUG = re.compile(r"^[a-z0-9][a-z0-9-]*$")
_cache: dict = {"key": None, "val": ([], "")}


def _stat(path: Path | str) -> tuple:
    try:
        st = os.stat(path)
        return (st.st_mtime_ns, st.st_size)
    except OSError:
        return ()


def _slugs(v) -> list[str]:
    out: list[str] = []
    for s in v if isinstance(v, (list, tuple)) else []:
        if isinstance(s, str) and _SLUG.match(s) and s not in out:
            out.append(s)
    return out


def _load() -> tuple[list[str], str]:
    toml = C._config_home() / "stackshot" / "stackshot.toml"
    cfg = os.environ.get("SALA_CONFIG") or str(Path.home() / ".config" / "salamander" / "config")
    key = (str(toml), _stat(toml), cfg, _stat(cfg), os.environ.get("SALA_SCOPES"), os.environ.get("SALA_DEFAULT_SCOPE"))
    if _cache["key"] == key:
        return _cache["val"]
    names = _slugs(C.sala_setting("SALA_SCOPES").split())
    default = ""
    if not names:
        sec = C._stackshot_toml().get("project_scopes")
        sec = sec if isinstance(sec, dict) else {}
        names = _slugs(sec.get("order"))
        default = sec.get("default") if names else ""
    if not (isinstance(default, str) and default in names):
        d = C.sala_setting("SALA_DEFAULT_SCOPE")
        default = d if d in names else (names[0] if names else "")
    _cache["key"], _cache["val"] = key, (names, default)
    return names, default


def names() -> list[str]:
    """The scopes, in the order they are shown ([] when none is configured)."""
    return list(_load()[0])


def default() -> str:
    """The scope a new project starts in: the configured default if it is one of the scopes, else the first, else ""."""
    return _load()[1]


def valid_shape(s) -> bool:
    return isinstance(s, str) and bool(_SLUG.match(s))
