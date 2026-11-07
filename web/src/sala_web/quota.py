"""Account quota per sala lane (subscription-1, subscription-2), as claude.ai's Usage screen shows it, from GET /api/oauth/usage.

Read-only on the sign-in: the access token is read from the lane's .credentials.json and sent as a bearer token,
nothing more. It is never refreshed here (a refresh rotates the token and can sign the CLI out), never written back,
and never put in a log, an error string or a response. An expired token waits for a session on that lane to renew it.
"""

from __future__ import annotations

import asyncio
import email.utils
import json
import re
import time
import urllib.error
import urllib.request
from datetime import timezone
from pathlib import Path

from . import lanestate as LS
from . import swr as SWR

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
TTL = 300.0          # a good answer is reused for 5 minutes
ERROR_RETRY = 55.0   # a failure that asked Anthropic nothing (no sign-in, or one expired) is looked at again at the
#                      page's next poll (every 60 s): the sign-in renews by itself when a session on the lane runs.
#                      A failure that did ask backs off instead (swr.py BACKOFF; a 429 waits what Retry-After says).
NO_SIGN_IN = "no sign-in on this lane"      # the lane has no sign-in file: the card reads this as "not configured" (sessions.js NOT_CONFIGURED_WORDS)
EXPIRED = "sign-in expired; it renews when a session on this lane next runs"
RATE_LIMITED = "Anthropic is limiting usage checks"  # a 429; the card words it from errorKind, with the saved time
REFUSED = "Anthropic refused the usage check"        # a 403; errorKind "refused" is what sala's watch reads
PLAN_NAMES = {"max": "Max", "pro": "Pro", "team": "Team", "enterprise": "Enterprise"}


class Expired(Exception):
    pass


def read_sign_in(lane_dir: Path) -> tuple[str, str | None]:
    """(access token, plan label) from <lane_dir>/.credentials.json. Raises Expired, or RuntimeError with a message
    that carries nothing from the file."""
    try:
        oauth = json.loads((lane_dir / ".credentials.json").read_text()).get("claudeAiOauth") or {}
    except FileNotFoundError:
        raise RuntimeError(NO_SIGN_IN) from None
    except (OSError, ValueError, AttributeError):
        raise RuntimeError("sign-in file unreadable") from None
    token = oauth.get("accessToken")
    if not isinstance(token, str) or not token:
        raise RuntimeError(NO_SIGN_IN)
    exp = oauth.get("expiresAt")
    if isinstance(exp, (int, float)) and exp / 1000 <= time.time():
        raise Expired()
    return token, plan_label(oauth.get("subscriptionType"), oauth.get("rateLimitTier"))


def read_plan(lane_dir: Path) -> str | None:
    """The plan label from <lane_dir>/.credentials.json alone, for a card that asks Anthropic nothing (a dormant lane's
    head). Unlike read_sign_in it does not mind an expired token; any trouble reading the file is None, never an error."""
    try:
        oauth = json.loads((lane_dir / ".credentials.json").read_text()).get("claudeAiOauth") or {}
        return plan_label(oauth.get("subscriptionType"), oauth.get("rateLimitTier"))
    except (OSError, ValueError, AttributeError):
        return None


def plan_label(sub: object, tier: object) -> str | None:
    """'Max (20x)' from subscriptionType 'max' and rateLimitTier '..._20x'; None when the type is not a known plan."""
    name = PLAN_NAMES.get(sub) if isinstance(sub, str) else None
    if not name:
        return None
    m = re.search(r"_(\d+)x$", tier) if isinstance(tier, str) else None
    return f"{name} ({m.group(1)}x)" if m else name


def limit_label(lim: dict) -> str:
    kind = lim.get("kind")
    if kind == "session":
        return "Current session"
    if kind == "weekly_all":
        return "This week"
    if kind == "weekly_scoped":
        model = ((lim.get("scope") or {}).get("model") or {}).get("display_name")
        return f"{model} this week" if isinstance(model, str) and model else "Scoped this week"
    return str(kind or "limit").replace("_", " ").capitalize()


def parse_limits(body: dict) -> list[dict]:
    out = []
    for lim in body.get("limits") or []:
        if not isinstance(lim, dict):
            continue
        pct = lim.get("percent")
        out.append({
            "label": limit_label(lim),
            "percent": pct if isinstance(pct, (int, float)) else None,
            "severity": lim.get("severity") or "normal",
            "resetsAt": lim.get("resets_at"),
        })
    return out


class Unauthorized(Exception):
    pass


class Refused(Exception):
    """HTTP 403: Anthropic knows the sign-in and refuses it the usage (a login whose access was withdrawn). Not an expired token
    (401), which renews by itself; sala's watch reads this kind in the saved answer and marks the lane dormant (salamander
    lib/watch.sh, THE DORMANT RECORD'S SIGNALS). UNVERIFIED which status such a login really gets."""


class RateLimited(Exception):
    """HTTP 429. retry_after: what its Retry-After header said, in seconds from now; None without one."""

    def __init__(self, retry_after: float | None = None):
        super().__init__("rate limited")
        self.retry_after = retry_after


class Unavailable(RuntimeError):
    """No usable answer from the usage endpoint: an HTTP error other than 401 and 429, no network, an unreadable body.
    The message names the status or the error type, never the token."""


def retry_after_seconds(value: str | None, now: float | None = None) -> float | None:
    """A Retry-After header as seconds from now: a count of seconds, or an HTTP date (RFC 9110); None when absent or
    unreadable. Not clamped here (swr.py clamps it to RETRY_AFTER_MIN..RETRY_AFTER_MAX)."""
    if not isinstance(value, str) or not value.strip():
        return None
    v = value.strip()
    if v.isdigit():
        return float(v)
    try:
        when = email.utils.parsedate_to_datetime(v)
    except (TypeError, ValueError, IndexError, OverflowError):
        return None
    if when is None:
        return None
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    return when.timestamp() - (time.time() if now is None else now)


def fetch_usage(token: str) -> dict:
    """GET the usage endpoint (blocking; run it in a thread). Raises Unauthorized on 401, Refused on 403, RateLimited on 429
    (with its Retry-After), Unavailable (a RuntimeError) otherwise."""
    req = urllib.request.Request(USAGE_URL, headers={
        "Authorization": f"Bearer {token}", "anthropic-beta": "oauth-2025-04-20", "User-Agent": "sala-web"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        if e.code == 401:
            raise Unauthorized() from None
        if e.code == 403:
            raise Refused() from None
        if e.code == 429:
            headers = e.headers if e.headers is not None else {}
            raise RateLimited(retry_after_seconds(headers.get("Retry-After"))) from None
        raise Unavailable(f"usage endpoint answered HTTP {e.code}") from None
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        raise Unavailable(f"usage endpoint unreachable ({type(e).__name__})") from None
    except ValueError:
        raise Unavailable("usage endpoint sent an unreadable answer") from None


class QuotaCache:
    """Per lane: the last good answer, served at once (kept in memory and, with a state dir, in a file per lane so a
    restart has it too) and refreshed in the background once it is TTL old, so no page waits on the usage endpoint.
    A failure keeps the last answer and adds an error with its kind: a 429 ("rate_limited") waits what Retry-After says
    (a minute to 3 hours) or 2, 4, 8, 16, then 30 minutes; any other answer or no answer ("failed") 1, 2, 4, 8, 16, then
    30; a missing or expired sign-in ("sign_in", nothing asked) is looked at again ERROR_RETRY later. Each lane backs
    off on its own, and the wait is saved with the lane's answer so a restart keeps it. While a lane waits its saved
    answer is served and nothing is sent. The file holds the limits, the plan name and the wait, never the token."""

    def __init__(self, lanes: dict[str, Path], fetch=fetch_usage, state_dir: Path | None = None):
        self.lanes = lanes
        self.fetch = fetch
        # the file is quota-<lane>.json; one an earlier version saved under the lane's old name (quota-max.json, quota-team.json:
        # lanestate.RENAMED) is read while the new one is not there, so a saved answer and the wait it carries are not stranded by the
        # rename; it is left as it is, and its "lane" is read as the new code
        self._swr = {lane: SWR.Revalidating(state_dir / f"quota-{lane}.json" if state_dir else None, TTL, ERROR_RETRY,
                                            {"lane": lane, "limits": []},
                                            valid=lambda d, lane=lane: LS.norm(d.get("lane")) == lane and isinstance(d.get("limits"), list),
                                            fallbacks=tuple(state_dir / f"quota-{old}.json" for old, new in LS.RENAMED.items() if new == lane) if state_dir else ())
                     for lane in lanes}
        for lane, r in self._swr.items():
            r.state["lane"] = lane   # an answer read from the old file says the old word: the new code, from here on and in what is saved next

    async def get(self, dormant: dict[str, dict] | None = None) -> list[dict]:
        """Each lane's answer. A lane the dormant record lists (sala's lane-state.tsv, lanestate.py) is a head and one line
        and no check: {"lane", "dormant": {"reason", "since"}, "plan"?, "fetchedAt"?} comes back and its cache is not touched,
        so nothing is asked. The plan is the sign-in file's word (read_plan); without it the card's head has no plan text.
        fetchedAt (epoch ms) is the time of the lane's last good reading kept in its saved answer, absent when it has none."""
        dormant = dormant or {}
        return [self._dormant(lane, dormant[lane]) if lane in dormant
                else self._swr[lane].serve(lambda lane=lane: self._refresh(lane)) for lane in self.lanes]

    def _dormant(self, lane: str, d: dict) -> dict:
        out = {"lane": lane, "dormant": d}
        plan = read_plan(self.lanes[lane])
        if plan:
            out["plan"] = plan
        # the time of the lane's last GOOD reading, from its saved answer (state_dir/quota-<lane>.json, untouched while dormant):
        # the card's "updated 3 days ago" line. Never the time of a try that failed; absent when the lane never answered.
        fetched = self._swr[lane].state.get("fetchedAt")
        if isinstance(fetched, int):
            out["fetchedAt"] = fetched
        return out

    async def _refresh(self, lane: str) -> dict:
        try:
            token, plan = read_sign_in(self.lanes[lane])
            body = await asyncio.to_thread(self.fetch, token)
            limits = parse_limits(body if isinstance(body, dict) else {})
        except (Expired, Unauthorized):
            raise SWR.Failed(EXPIRED, kind="sign_in") from None
        except Refused:
            raise SWR.Failed(REFUSED, kind="refused", backoff=True) from None
        except RateLimited as e:
            raise SWR.Failed(RATE_LIMITED, kind="rate_limited", backoff=True, retry_after=e.retry_after) from None
        except Unavailable as e:
            raise SWR.Failed(str(e), backoff=True) from None
        except RuntimeError as e:  # read_sign_in: no sign-in on the lane, or its file unreadable; nothing was asked
            raise SWR.Failed(str(e), kind="sign_in") from None
        except Exception as e:  # never str(e): an unexpected error could carry anything
            raise SWR.Failed(f"quota could not be read ({type(e).__name__})", backoff=True) from None
        out = {"lane": lane, "limits": limits}
        plan = plan or self._swr[lane].state.get("plan")
        if plan:
            out["plan"] = plan
        return out
