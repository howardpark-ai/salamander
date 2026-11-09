"""The Usage analysis count as a job of its own: `python -m sala_web.usage_job` (contrib/sala-web-usage-count runs it with the web app's virtual environment).

It makes the count the tab shows, once, with the code the tab's Reload uses (`usage.UsageCache.count`), and leaves it where the app reads it
(the state dir: usage-answer.json, usage-replies.json, usage-scan.json). The app notices the newer files by itself and serves them; a visit to the tab never counts
(usage.py). Nothing is asked of Anthropic or AWS: the weekly reset the weeks hang on is the one the lane cards last saved (quota-<lane>.json), read and not
refreshed. The exit status is 0 when it counted and saved, 1 when the count failed (one line on stderr, in plain words, never an exception's own text;
the last saved count stays in place), 2 for a wrong command line. It runs from a timer once a day (README, Usage analysis).
"""

from __future__ import annotations

import argparse
import asyncio
import sys

from . import lanenames as LNM
from . import lanes as LN
from . import lanestate as LS
from . import quota as Q
from . import sessions as S
from . import spawn as SP
from . import usage as USG
from .config import Settings


def build_cache(settings: Settings) -> USG.UsageCache:
    """The usage cache over this machine's own settings, with no running app: the sala command for the lane table and names, the saved quota answers."""
    async def lane_table() -> list[dict]:
        rc, out, _err = await SP.run([*SP.resolve_cmd(settings.sala_cmd), "lane", "--json"], LN.TIMEOUT)
        return LN.parse_table(out) if rc == 0 else []

    async def run_lane_names() -> str | None:
        try:
            rc, out, _err = await SP.run([*SP.resolve_cmd(settings.sala_cmd), "lane", "names", "--json"], LNM.TIMEOUT)
        except (OSError, TimeoutError):
            return None
        return out if rc == 0 else None

    quota = Q.QuotaCache({"subscription-1": settings.claude_dir, **S.LANE_DIRS}, state_dir=settings.state_dir)

    async def saved_quota() -> list[dict]:
        return quota.saved(LS.dormant(settings.sala_state_dir / "lane-state.tsv"))

    lane_names = LNM.LaneNames(run_lane_names, settings.sala_state_dir)
    return USG.UsageCache(settings, lambda: S.read_live_sessions(settings), lane_table, lane_names.rows, saved_quota)


async def run(settings: Settings) -> int:
    err = await build_cache(settings).count()
    if err:
        print(f"sala-web usage count failed: {err}", file=sys.stderr)
        return 1
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="python -m sala_web.usage_job", description=__doc__.splitlines()[0])
    ap.parse_args(argv)
    return asyncio.run(run(Settings()))


if __name__ == "__main__":
    sys.exit(main())
