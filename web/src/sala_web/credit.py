"""What the API key has spent, today and this month in the SALA_TZ zone (local time when unset), from the Admin API (GET only).

The metered (api) and sdk lanes bill the same key at the same per-token prices, and the Admin API cannot tell them
apart, so this is one figure for both, counting what is spent rather than a remaining balance.

The two reports do not line up with a day of that zone (the text below takes a zone at UTC+4 as the example): the cost report is in complete UTC days (amounts are US cents, as
decimal strings; it leaves out the current UTC day and can lag), the usage report in UTC hours of tokens. So every
hour since the month began gets a cost:

- an hour of a UTC day the cost report has: exact, that day's amount shared out over its hours by their usage;
- any later hour (the latest ones): estimated from that hour's tokens, priced at rates calibrated from the cost report
  itself (amount / tokens per model, context window and token type, on the latest complete day that has that key).
  There is no price table here; tokens with no calibrated rate are counted and reported as unpriced, never guessed.

Then the hours are summed into the zone's day and month (for a zone at UTC+4: an hour from 20:00 UTC on is the next day).

The Admin API key is read from its file at each refresh and only ever sent as the x-api-key header: never logged,
never put in an error string or a response. HTTP errors carry only their status code.
"""

from __future__ import annotations

import asyncio
import json
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

from . import swr as SWR
from . import tz

API = "https://api.anthropic.com"
COST_PATH = "/v1/organizations/cost_report"
USAGE_PATH = "/v1/organizations/usage_report/messages"
CONSOLE_URL = "https://platform.claude.com/settings/billing"
TTL = 900.0          # one upstream refresh per 15 minutes, however many viewers ask
ERROR_RETRY = 60.0   # after a failure, try again a minute later
CALIBRATION_DAYS = 7  # complete cost days before the month's first fetched to calibrate rates
HOUR = timedelta(hours=1)
DAY = timedelta(days=1)
TOKEN_FIELDS = ("uncached_input_tokens", "cache_read_input_tokens", "output_tokens")
WEB_SEARCH = "web_search_requests"


NO_KEY = "No Admin API key on this machine."   # the card reads this as "not configured" (sessions.js NOT_CONFIGURED_WORDS)


class ConfigError(Exception):
    """A plain message for the card (never carries a secret)."""


def read_key(path: Path) -> str:
    try:
        key = path.read_text().strip()
    except FileNotFoundError:
        raise ConfigError(NO_KEY) from None
    except OSError:
        raise ConfigError("The Admin API key file could not be read.") from None
    if not key:
        raise ConfigError("The Admin API key file is empty.")
    return key


def parse_ts(s: str) -> datetime:
    d = datetime.fromisoformat(s.replace("Z", "+00:00"))
    if d.tzinfo is None:
        d = d.replace(tzinfo=timezone.utc)
    return d.astimezone(timezone.utc)


def iso(d: datetime) -> str:
    return d.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def fetch_admin(key: str, path: str, params: dict) -> dict:
    """One GET to the Admin API (blocking; run it in a thread). RuntimeError carries only a status or error type."""
    url = f"{API}{path}?{urllib.parse.urlencode(params, doseq=True)}"
    req = urllib.request.Request(url, headers={
        "x-api-key": key, "anthropic-version": "2023-06-01", "User-Agent": "sala-web"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"Admin API answered HTTP {e.code}") from None
    except urllib.error.URLError as e:  # the reason names the network fault (a timeout, a refused or reset link); no key or URL in it
        raise RuntimeError(f"Admin API unreachable ({str(e.reason)[:80]})") from None
    except (TimeoutError, OSError) as e:
        raise RuntimeError(f"Admin API unreachable ({type(e).__name__})") from None
    except ValueError:
        raise RuntimeError("Admin API sent an unreadable answer") from None


def fetch_buckets(fetch, key: str, path: str, params: dict) -> list[dict]:
    """Every bucket of a report, following next_page."""
    out, page = [], None
    for _ in range(50):
        p = dict(params, page=page) if page else params
        body = fetch(key, path, p)
        if not isinstance(body, dict):
            raise RuntimeError("Admin API sent an unexpected answer")
        out.extend(b for b in body.get("data") or [] if isinstance(b, dict))
        page = body.get("next_page")
        if not body.get("has_more") or not page:
            return out
    raise RuntimeError("Admin API kept paging")


def usage_tokens(r: dict) -> dict[str, float]:
    """Token counts of one usage result, keyed as the cost report's token_type, plus web search requests."""
    out = {}
    for f in TOKEN_FIELDS:
        v = r.get(f)
        if isinstance(v, (int, float)) and v:
            out[f] = v
    for k, v in (r.get("cache_creation") or {}).items():
        if isinstance(v, (int, float)) and v:
            out[f"cache_creation.{k}"] = v
    v = (r.get("server_tool_use") or {}).get(WEB_SEARCH)
    if isinstance(v, (int, float)) and v:
        out[WEB_SEARCH] = v
    return out


def rate_key(model, window, ttype: str) -> tuple:
    # web search is priced per request, the same for every model
    return (WEB_SEARCH,) if ttype == WEB_SEARCH else (model, window, ttype)


def calibrate(cost_days: dict[date, list], usage_days: dict[date, list]) -> tuple[dict, date | None]:
    """{rate key: cents per token (or per search)} from the latest complete day that has both an amount and a
    count for that key; and the latest day used."""
    rates, latest = {}, None
    for day in sorted(cost_days, reverse=True):
        amounts = defaultdict(float)
        for r in cost_days[day]:
            try:
                a = float(r.get("amount"))
            except (TypeError, ValueError):
                continue
            if r.get("cost_type") == "tokens" and r.get("token_type"):
                amounts[(r.get("model"), r.get("context_window"), r["token_type"])] += a
            elif r.get("cost_type") == "web_search":
                amounts[(WEB_SEARCH,)] += a
        counts = defaultdict(float)
        for r in usage_days.get(day, []):
            for t, n in usage_tokens(r).items():
                counts[rate_key(r.get("model"), r.get("context_window"), t)] += n
        for k, a in amounts.items():
            if k not in rates and a > 0 and counts.get(k, 0) > 0:
                rates[k] = a / counts[k]
                latest = max(latest, day) if latest else day
    return rates, latest


def price(results: list, rates: dict, unknown: dict | None = None) -> float:
    """Estimated cents for a list of usage results; tokens with no rate go into unknown[(model, type)] when given."""
    cents = 0.0
    for r in results:
        for t, n in usage_tokens(r).items():
            k = rate_key(r.get("model"), r.get("context_window"), t)
            if k in rates:
                cents += n * rates[k]
            elif unknown is not None:
                uk = (None if t == WEB_SEARCH else r.get("model"), t)
                unknown[uk] = unknown.get(uk, 0) + n
    return cents


def by_day(buckets: list[dict], now: datetime) -> dict[date, list]:
    """Results of the daily buckets that have ended."""
    out = {}
    for b in buckets:
        try:
            start, end = parse_ts(b["starting_at"]), parse_ts(b["ending_at"])
        except (KeyError, TypeError, ValueError):
            continue
        if end <= now:
            out[start.date()] = [r for r in b.get("results") or [] if isinstance(r, dict)]
    return out


def has_tokens(results: list) -> bool:
    return any(usage_tokens(r) for r in results)


def day_cents(results: list) -> float:
    total = 0.0
    for r in results:
        try:
            total += float(r.get("amount") or 0)
        except (TypeError, ValueError):
            continue
    return total


def compute(key: str, fetch, now: datetime) -> dict:
    now_zone = tz.convert(now)
    today0 = now_zone.replace(hour=0, minute=0, second=0, microsecond=0)
    month0 = today0.replace(day=1)
    # the UTC day the zone's month starts in (for a zone at UTC+4 the day before, from 20:00 UTC): its whole day is fetched, so its cost can
    # be shared out over all of its hours
    first_day = month0.astimezone(timezone.utc).date()
    day0 = datetime.combine(first_day, datetime.min.time(), timezone.utc)
    cal0 = day0 - timedelta(days=CALIBRATION_DAYS)
    cost_days = by_day(fetch_buckets(fetch, key, COST_PATH, {
        "starting_at": iso(cal0), "group_by[]": ["description"], "limit": 31}), now)
    usage_days = by_day(fetch_buckets(fetch, key, USAGE_PATH, {
        "starting_at": iso(cal0), "bucket_width": "1d", "group_by[]": ["model", "context_window"], "limit": 31}), now)
    hours = []
    for b in fetch_buckets(fetch, key, USAGE_PATH, {
            "starting_at": iso(day0), "bucket_width": "1h", "group_by[]": ["model", "context_window"], "limit": 168}):
        try:
            s, e = parse_ts(b["starting_at"]), parse_ts(b["ending_at"])
        except (KeyError, TypeError, ValueError):
            continue
        if e <= now:  # the hour still running is left out
            hours.append((s, e, [r for r in b.get("results") or [] if isinstance(r, dict)]))

    rates, cal_day = calibrate(cost_days, usage_days)

    # a UTC day is exact when the cost report has it, unless it is an empty day the usage report says had traffic
    # (a cost report still catching up)
    exact_days = {d for d, res in cost_days.items()
                  if d >= first_day and (res or not has_tokens(usage_days.get(d, [])))}

    # each exact day's amount shared over its hours: by their priced usage, else by their token counts, else evenly
    hours_of: dict[date, list] = defaultdict(list)
    for h in hours:
        if h[0].date() in exact_days:
            hours_of[h[0].date()].append(h)
    cents_at: dict[datetime, float] = {}
    for d in exact_days:
        total = day_cents(cost_days[d])
        hs = hours_of.get(d, [])
        weights = [price(r, rates) for _, _, r in hs]
        if not sum(weights):
            weights = [sum(sum(usage_tokens(x).values()) for x in r) for _, _, r in hs]
        if sum(weights):
            for (s, _, _), w in zip(hs, weights):
                cents_at[s] = total * w / sum(weights)
        else:  # no hour has any usage: an even share of each of the day's 24 hours
            s0 = datetime.combine(d, datetime.min.time(), timezone.utc)
            for i in range(24):
                cents_at[s0 + i * HOUR] = total / 24

    unknown: dict[tuple, float] = {}
    estimated_at: dict[datetime, float] = {}
    usage_through = None
    for s, e, results in hours:
        usage_through = max(usage_through, e) if usage_through else e
        if s.date() not in exact_days and s >= month0:
            estimated_at[s] = price(results, rates, unknown)

    def total(table: dict, since: datetime) -> float:
        return sum(c for s, c in table.items() if since <= s < now)

    month_exact, today_exact = total(cents_at, month0), total(cents_at, today0)
    month_est, today_est = total(estimated_at, month0), total(estimated_at, today0)
    exact_through = (datetime.combine(max(exact_days), datetime.min.time(), timezone.utc) + DAY) if exact_days else None
    est_hours = sorted(s for s, c in estimated_at.items() if c > 0)
    return {
        "today": today0.date().isoformat(),
        "month": month0.strftime("%Y-%m"),
        "todayUsd": round((today_exact + today_est) / 100, 2),
        "monthUsd": round((month_exact + month_est) / 100, 2),
        "todayEstimatedUsd": round(today_est / 100, 2),
        "monthEstimatedUsd": round(month_est / 100, 2),
        # the hours priced from usage: the latest ones, which the cost report does not have yet
        "estimatedFrom": iso(est_hours[0]) if est_hours else None,
        "exactThrough": iso(exact_through) if exact_through else None,
        "usageThrough": iso(usage_through) if usage_through else None,
        "calibratedOn": cal_day.isoformat() if cal_day else None,
        "unpriced": [{"model": m, "type": t, "count": round(n)}
                     for (m, t), n in sorted(unknown.items(), key=lambda kv: -kv[1]) if n >= 1],
        "consoleUrl": CONSOLE_URL,
    }


class CreditCache:
    """The spend, served at once from the last good answer (kept in memory and in a file under the state dir, so a
    restart has it too) and refreshed in the background once it is TTL old: every viewer and every open of the
    overview reads this, so the Admin API is asked at most once per TTL, and no page waits on it. A failure keeps the
    last answer, adds an error and is retried a minute later."""

    def __init__(self, key_path: Path, state_path: Path | None = None, fetch=fetch_admin):
        self.key_path = key_path
        self.fetch = fetch
        self._swr = SWR.Revalidating(state_path, TTL, ERROR_RETRY, {"consoleUrl": CONSOLE_URL},
                                     valid=lambda d: isinstance(d.get("todayUsd"), (int, float)))

    async def get(self) -> dict:
        return self._swr.serve(self._refresh)

    async def _refresh(self) -> dict:
        try:
            key = read_key(self.key_path)
            return await asyncio.to_thread(compute, key, self.fetch, datetime.now(timezone.utc))
        except (ConfigError, RuntimeError) as e:
            raise SWR.Failed(str(e)) from None
        except Exception as e:  # never str(e): an unexpected error could carry anything
            raise SWR.Failed(f"spend could not be read ({type(e).__name__})") from None
