"""The dormant record, read-only (salamander lib/common.sh, "THE DORMANT RECORD").

sala keeps one record per lane, active or dormant, in `lane-state.tsv` beside its other state: one row per lane that ever
changed state, `lane TAB state TAB reason TAB since (ISO, UTC) TAB posted TAB by`, keyed by the lane's id (sdk is the api
lane's alias and is read as api). An absent row, or no file, is active. This app only reads it: a dormant lane's Overview
card is one line and makes no usage check, and the New session form does not offer the lane. The file is sala's; nothing
here writes it, and an unreadable or odd line is skipped, which reads as active.
"""

from __future__ import annotations

from pathlib import Path

# The words a lane is also called, and the ONE place they are read as the lane (every reader here goes through norm or renamed; the
# page's laneNorm in static/shared.js is the same table). RENAMED are old names of a lane that still stand in what sala wrote before
# the rename and in a pane that runs on the old word: awsplatform became aws-platform, max became subscription-1 and
# team subscription-2. Nothing stored is rewritten; a read says the new code, a write carries it.
RENAMED = {"awsplatform": "aws-platform", "max": "subscription-1", "team": "subscription-2"}
ALIASES = {"sdk": "api", **RENAMED}   # sdk is also a word for api (a lane-state.tsv row, a log line), which is not an old name


def norm(lane):
    """A lane word as the lane's code: sdk reads as api and an old name as its new one; any other value comes back as it is."""
    return ALIASES.get(lane, lane) if isinstance(lane, str) else lane


def renamed(lane):
    """A lane word with an old name read as the new one, sdk left alone: for a place that tells sdk from api (a unit's
    X-Model-Lane, a spawn payload, the table's default)."""
    return RENAMED.get(lane, lane) if isinstance(lane, str) else lane


def dormant(path: Path) -> dict[str, dict]:
    """{lane id: {"reason": str, "since": ISO string}} for each lane the record says is dormant; {} when it says none."""
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return {}
    out: dict[str, dict] = {}
    for line in text.splitlines():
        cols = line.split("\t")
        if len(cols) < 4 or cols[1] != "dormant" or not cols[0]:
            continue
        out[norm(cols[0])] = {"reason": cols[2], "since": cols[3]}
    return out
