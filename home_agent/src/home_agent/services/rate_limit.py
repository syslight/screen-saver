from __future__ import annotations

import time
from collections import defaultdict, deque

from home_agent.errors import DomainError


class InMemoryRateLimiter:
    def __init__(self, *, limit: int = 10, window_seconds: float = 60.0) -> None:
        self.limit = limit
        self.window_seconds = window_seconds
        self._attempts: dict[str, deque[float]] = defaultdict(deque)

    def check(self, key: str) -> None:
        now = time.monotonic()
        attempts = self._attempts[key]
        while attempts and attempts[0] <= now - self.window_seconds:
            attempts.popleft()
        if len(attempts) >= self.limit:
            raise DomainError("rate_limited", "Too many attempts", status_code=429)
        attempts.append(now)
