"""The lane words, for sala's Python helpers (sessions.py, unitjob.py): the twin of common.sh's lane_norm and lane_label.

A lane's CODE is what files and commands carry (subscription-1, subscription-2, api, ...); the words max and team (and
awsplatform) are the old words of lanes that were renamed, and are read as the lane's current code wherever a lane word is read:
a registry row, a unit's X-Model-Lane=, a stored file written before the rename. The DISPLAY NAME (Ultra, Team) is one setting, the lane's label field in common.sh (SALA_LANE_<ID>_LABEL in the sala config), and this module
reads it from the table `salamander lane names` keeps in $SALA_STATE_DIR/lane-names.json (sala-watch rewrites it when the config or
sala's code changes), so a change to the setting changes every place at once. Only when there is no file does this module's own fixed fallback
(DEFAULT_NAMES, the table's defaults) answer, and it runs nothing.

Imported by path (the helpers run with `python3 -I -S`, which leaves the script's own folder off sys.path):
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import lanewords
"""
import json
import os

# the old words of renamed lanes, read as the lane's current code (the table common.sh keeps as SALA_LANE_RENAMED)
ALIASES = {"awsplatform": "aws-platform", "max": "subscription-1", "team": "subscription-2"}


def norm_lane(v):
    """The current code of a lane word (an old word becomes its lane's code); anything else as it came."""
    return ALIASES.get(v, v) if isinstance(v, str) else v


def _state_dir():
    return os.environ.get("SALA_STATE_DIR") or os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), "salamander")


# The names a lane shows when sala's file is missing or unreadable: the two renamed lanes' defaults, any other lane as its own code.
DEFAULT_NAMES = {"subscription-1": "Ultra", "subscription-2": "Team"}
_cache = {}   # per process: the parsed table, keyed on the file's mtime (and size), so a rewrite is seen and an unchanged file is read once


def lane_names():
    """The lane table {code: display name} from sala's state file (lane-names.json, kept current by sala-watch), parsed once per
    process and again only when the file changes; with no readable file, the fixed defaults (no command is run to ask sala)."""
    path = os.path.join(_state_dir(), "lane-names.json")
    try:
        st = os.stat(path)
        key = (path, st.st_mtime_ns, st.st_size)
    except OSError:
        return dict(DEFAULT_NAMES)
    hit = _cache.get("names")
    if hit and hit[0] == key:
        return hit[1]
    names = {}
    try:
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
        for row in (doc or {}).get("lanes") or []:
            if isinstance(row, dict) and isinstance(row.get("code"), str) and isinstance(row.get("display"), str):
                names[row["code"]] = row["display"]
    except (OSError, ValueError, AttributeError):
        return dict(DEFAULT_NAMES)
    names = names or dict(DEFAULT_NAMES)
    _cache["names"] = (key, names)
    return names


def lane_label(lane):
    """How a lane is shown: its display name (Ultra, Team, API, ...); the code itself when sala has no name for it."""
    code = norm_lane(lane)
    return lane_names().get(code) or DEFAULT_NAMES.get(code) or (code if isinstance(code, str) else "")
