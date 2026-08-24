"""Market research inputs: bars, the live quote, and recent headlines."""

from __future__ import annotations

import csv
import json
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Protocol, Sequence

from .alpaca_client import AlpacaHTTP
from .indicators import Bar


def _parse_ts(raw: str) -> datetime:
    """Alpaca returns RFC-3339 with a trailing Z."""
    return datetime.fromisoformat(raw.replace("Z", "+00:00"))


@dataclass(frozen=True)
class Quote:
    ts: datetime
    bid: float
    ask: float

    @property
    def mid(self) -> float:
        if self.bid > 0 and self.ask > 0:
            return (self.bid + self.ask) / 2
        return self.ask or self.bid

    @property
    def spread(self) -> float:
        return max(self.ask - self.bid, 0.0)

    def age_seconds(self, now: datetime | None = None) -> float:
        now = now or datetime.now(timezone.utc)
        return (now - self.ts).total_seconds()


@dataclass(frozen=True)
class Headline:
    ts: datetime
    headline: str
    source: str
    url: str = ""


class MarketDataProvider(Protocol):
    def bars(self, symbol: str, *, timeframe: str, limit: int) -> list[Bar]: ...
    def latest_quote(self, symbol: str) -> Quote: ...
    def news(self, symbol: str, *, limit: int) -> list[Headline]: ...


class AlpacaMarketData:
    """Reads Alpaca's market data API (v2 bars/quotes, v1beta1 news)."""

    def __init__(self, http: AlpacaHTTP) -> None:
        self._http = http

    def bars(self, symbol: str, *, timeframe: str = "1Day", limit: int = 120) -> list[Bar]:
        # Ask for a generous window; `limit` trims to the most recent bars.
        span = timedelta(days=limit * 3 if timeframe.endswith("Day") else 10)
        payload = self._http.data_get(
            f"/v2/stocks/{symbol}/bars",
            params={
                "timeframe": timeframe,
                "start": (datetime.now(timezone.utc) - span).date().isoformat(),
                "limit": limit,
                "adjustment": "split",
                "feed": self._http.settings.feed,
                "sort": "asc",
            },
        )
        raw = (payload or {}).get("bars") or []
        bars = [
            Bar(
                ts=_parse_ts(b["t"]),
                open=float(b["o"]),
                high=float(b["h"]),
                low=float(b["l"]),
                close=float(b["c"]),
                volume=float(b.get("v", 0)),
            )
            for b in raw
        ]
        return bars[-limit:]

    def latest_quote(self, symbol: str) -> Quote:
        payload = self._http.data_get(
            f"/v2/stocks/{symbol}/quotes/latest",
            params={"feed": self._http.settings.feed},
        )
        q = (payload or {}).get("quote") or {}
        if not q:
            raise ValueError(f"no quote returned for {symbol}")
        return Quote(ts=_parse_ts(q["t"]), bid=float(q.get("bp", 0)), ask=float(q.get("ap", 0)))

    def news(self, symbol: str, *, limit: int = 8) -> list[Headline]:
        try:
            payload = self._http.data_get(
                "/v1beta1/news",
                params={"symbols": symbol, "limit": limit, "sort": "desc"},
            )
        except Exception:
            # Headlines are enrichment, never a precondition for a decision.
            return []
        return [
            Headline(
                ts=_parse_ts(n["created_at"]),
                headline=n.get("headline", ""),
                source=n.get("source", ""),
                url=n.get("url", ""),
            )
            for n in (payload or {}).get("news", [])
        ]


class FixtureMarketData:
    """Offline provider backed by CSV bars — used by tests and `--offline` runs."""

    def __init__(
        self,
        bars: Sequence[Bar],
        quote: Quote | None = None,
        headlines: Sequence[Headline] = (),
    ) -> None:
        self._bars = list(bars)
        last = self._bars[-1].close if self._bars else 0.0
        self._quote = quote or Quote(
            ts=datetime.now(timezone.utc), bid=last * 0.9995, ask=last * 1.0005
        )
        self._headlines = list(headlines)

    @classmethod
    def from_csv(cls, path: str | Path, **kwargs: Any) -> "FixtureMarketData":
        rows: list[Bar] = []
        with open(path, newline="") as fh:
            for row in csv.DictReader(fh):
                rows.append(
                    Bar(
                        ts=_parse_ts(row["t"]),
                        open=float(row["o"]),
                        high=float(row["h"]),
                        low=float(row["l"]),
                        close=float(row["c"]),
                        volume=float(row.get("v", 0) or 0),
                    )
                )
        return cls(rows, **kwargs)

    def bars(self, symbol: str, *, timeframe: str = "1Day", limit: int = 120) -> list[Bar]:
        return self._bars[-limit:]

    def latest_quote(self, symbol: str) -> Quote:
        return self._quote

    def news(self, symbol: str, *, limit: int = 8) -> list[Headline]:
        return self._headlines[:limit]
