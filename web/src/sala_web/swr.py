"""Stale-while-revalidate for the overview's cards (the sdk lane card used to appear late
when the Overview loaded): a request is never kept waiting on Anthropic.

A Revalidating holds one answer. `serve` hands back the last answer at once and, when it is due, starts one refresh in
the background; a second request while that refresh runs starts no other, so upstream is asked at most once per TTL
however many pages poll. A good answer is written to a file under the state dir (atomically: a temp file renamed over
the old one), so a restart serves it straight away and refreshes only once it is due by its own fetch time. The file
holds only what the response carries (figures, times, a plan name): the caller passes no token or key into it, and an
error string is never saved. With no file yet the answer is {"pending": true, ...}: the page draws its placeholder and
asks again until the first refresh lands.

A failed refresh keeps the last answer and puts the failure on it: "error" (the caller's plain message), "errorKind"
("failed", or the caller's own word such as "rate_limited" or "sign_in") and "nextTry" (epoch ms). When the failure asked
upstream and was refused or got no answer (Failed with backoff=True), the next try backs off: BACKOFF[n] for the n-th
failure in a row (1, 2, 4, 8, 16, then 30 minutes; a rate limit starts at 2), or exactly what upstream's Retry-After
said, clamped to RETRY_AFTER_MIN..RETRY_AFTER_MAX; a success resets the count. Such a wait is saved with the answer
("nextTry" and "errorKind", never the error text), so a restart keeps waiting instead of asking again at once (
a 429 from the usage endpoint was retried every 55 s, which kept the refusal going). Until the wait is over `serve`
makes no call. A failure that asked upstream nothing (a missing sign-in) is tried again error_retry later, as before.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import os
import tempfile
import time
from pathlib import Path
from typing import Awaitable, Callable

BACKOFF = (60.0, 120.0, 240.0, 480.0, 960.0, 1800.0)  # the n-th failure in a row waits BACKOFF[n]; the last one from then on
RETRY_AFTER_MIN = 60.0          # a Retry-After shorter than a minute is a minute: the page polls every 60 s anyway
RETRY_AFTER_MAX = 3 * 3600.0    # and one longer than 3 hours is 3 hours: a wrong clock upstream must not park the card
RESUMED = {  # the message after a restart, while a saved wait is still ahead (the error text itself is never saved)
    "rate_limited": "Anthropic is limiting usage checks; waiting as told",
    "failed": "the last check failed; waiting before the next",
}
FLAGS = ("error", "pending", "refreshing")  # on the answer, never in the file


class Failed(Exception):
    """A refresh that did not get an answer; its message (never a secret) goes on the kept answer as "error", its kind as
    "errorKind". backoff=True when upstream was asked and refused or did not answer: the next try then backs off (see the
    module docstring), waiting retry_after seconds when upstream said so. Without it the next try is error_retry away."""

    def __init__(self, message: str, kind: str = "failed", backoff: bool = False, retry_after: float | None = None):
        super().__init__(message)
        self.kind = kind
        self.backoff = backoff
        self.retry_after = retry_after


class Revalidating:
    def __init__(self, path: Path | None, ttl: float, error_retry: float, empty: dict,
                 valid: Callable[[dict], bool] = lambda d: True, fallbacks: tuple[Path, ...] = ()):
        self.path = path
        self.fallbacks = fallbacks   # older names of the file, read when path holds no usable answer; never written, never removed
        self.ttl = ttl
        self.error_retry = error_retry
        self.state: dict = {**empty, "fetchedAt": None, "pending": True}
        self._next = 0.0  # monotonic time from which a refresh is due
        self._fails = 0   # backing-off failures in a row; a success resets it
        self._task: asyncio.Task | None = None
        self._load(valid)

    def _load(self, valid) -> None:
        if not self.path:
            return
        saved = None
        for p in (self.path, *self.fallbacks):
            try:
                got = json.loads(p.read_text())
            except (OSError, ValueError):
                continue
            if isinstance(got, dict) and valid(got):
                saved = got
                break
        if saved is None:
            return
        fetched, next_try = saved.get("fetchedAt"), saved.get("nextTry")
        if not isinstance(fetched, int) and not isinstance(next_try, int):
            return
        for k in FLAGS:
            saved.pop(k, None)
        now = time.time()
        due = fetched / 1000 + self.ttl if isinstance(fetched, int) else now
        if isinstance(next_try, int) and next_try / 1000 > now:
            # a failure's wait, still ahead: kept, and said on the answer with its kind
            due = max(due, next_try / 1000)
            kind = saved.get("errorKind") if isinstance(saved.get("errorKind"), str) else "failed"
            saved.update(errorKind=kind, error=RESUMED.get(kind, RESUMED["failed"]))
        else:
            saved.pop("nextTry", None)
            saved.pop("errorKind", None)
        if not isinstance(fetched, int):  # no good answer yet, only the wait: the empty answer stays pending, with it
            saved = {**self.state, **{k: saved[k] for k in ("nextTry", "errorKind", "error") if k in saved}}
        self.state = saved
        self._next = time.monotonic() + max(0.0, due - now)

    def serve(self, refresh: Callable[[], Awaitable[dict]]) -> dict:
        """The answer now; a background refresh started when one is due and none runs."""
        if time.monotonic() >= self._next and not self.running:
            self._task = asyncio.get_running_loop().create_task(self._run(refresh))
        out = dict(self.state)
        if self.running:
            out["refreshing"] = True
        return out

    def expire(self) -> None:
        """Make the answer due now: the next `serve` starts a refresh (a refresh already running is left to finish)."""
        self._next = 0.0

    @property
    def running(self) -> bool:
        return self._task is not None and not self._task.done()

    async def _run(self, refresh) -> None:
        try:
            got = await refresh()
        except Failed as e:
            await self._failed(e)
            return
        except Exception as e:  # never str(e): an unexpected error could carry anything
            await self._failed(Failed(f"could not be read ({type(e).__name__})"))
            return
        self._fails = 0
        self.state = {**got, "fetchedAt": int(time.time() * 1000)}
        self._next = time.monotonic() + self.ttl
        await self._save()

    async def _failed(self, e: Failed) -> None:
        """The last answer kept with the failure on it; the next try scheduled, and saved when it backs off."""
        delay = self._delay(e)
        self.state.update(error=str(e), errorKind=e.kind, nextTry=int((time.time() + delay) * 1000))
        self._next = time.monotonic() + delay
        if e.backoff:
            await self._save()

    def _delay(self, e: Failed) -> float:
        if not e.backoff:
            return self.error_retry
        step, self._fails = self._fails, self._fails + 1
        if e.retry_after is not None:
            return min(max(e.retry_after, RETRY_AFTER_MIN), RETRY_AFTER_MAX)
        if e.kind == "rate_limited":
            step += 1  # a refusal is never retried after one minute: 2, 4, 8, 16, 30
        return BACKOFF[min(step, len(BACKOFF) - 1)]

    async def _save(self) -> None:
        """The answer on disk: its figures, times and a pending wait; never the error text or the flags."""
        if not self.path:
            return
        data = {k: v for k, v in self.state.items() if k not in FLAGS}
        with contextlib.suppress(OSError):
            await asyncio.to_thread(write_atomic, self.path, data)


def write_atomic(path: Path, data: dict) -> None:
    """A temp file in the same directory, fsynced, then renamed over the old one: a reader sees the old answer or the
    new one, never half a file. Owner-only, as the rest of the state dir."""
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.stem}-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, ensure_ascii=False)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise
