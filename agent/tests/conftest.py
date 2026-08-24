from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Optional, Sequence

import pytest

from research_agent.broker import Account, MarketClock, Position
from research_agent.config import MARKET_TZ, RiskPolicy
from research_agent.indicators import Bar
from research_agent.market_data import FixtureMarketData, Quote
from research_agent.portfolio import PortfolioExposure, assess
from research_agent.research import ResearchBrief, build_brief

BASE = datetime(2026, 3, 2, 14, 0, tzinfo=timezone.utc)  # a Monday, 09:00 ET


def make_bars(closes: Sequence[float], *, spread: float = 1.0) -> list[Bar]:
    """Build bars with a controllable high/low band around each close."""
    return [
        Bar(
            ts=BASE + timedelta(days=i),
            open=c,
            high=c + spread / 2,
            low=c - spread / 2,
            close=c,
            volume=1_000_000,
        )
        for i, c in enumerate(closes)
    ]


def flat_closes(n: int = 60, price: float = 100.0) -> list[float]:
    """Alternating +/- so RSI lands mid-range and ATR is non-zero."""
    return [price + (1 if i % 2 else -1) * 0.5 for i in range(n)]


def rising_closes(n: int = 60, start: float = 50.0, step: float = 1.0) -> list[float]:
    return [start + i * step for i in range(n)]


def falling_closes(n: int = 60, start: float = 200.0, step: float = 1.0) -> list[float]:
    return [start - i * step for i in range(n)]


def uncorrelated_bars(symbols: Sequence[str], n: int = 90) -> dict[str, list[Bar]]:
    """Deterministic pseudo-random return series, mutually near-uncorrelated.

    Lets a test exercise one risk cap without the correlation cap firing.
    """
    out: dict[str, list[Bar]] = {}
    for k, symbol in enumerate(symbols):
        state = 1_234_567 + k * 7_919
        closes = [100.0]
        for _ in range(n):
            state = (1_103_515_245 * state + 12_345) % (2 ** 31)
            closes.append(closes[-1] * (1 + (state / 2 ** 31 - 0.5) * 0.03))
        out[symbol.upper()] = make_bars(closes)
    return out


@pytest.fixture
def policy() -> RiskPolicy:
    return RiskPolicy()


@pytest.fixture
def account() -> Account:
    return Account(
        account_number="PA_TEST",
        portfolio_value=100_000.0,
        buying_power=200_000.0,
        cash=100_000.0,
        equity=100_000.0,
        trading_blocked=False,
        pattern_day_trader=False,
    )


def et(y: int, m: int, d: int, hh: int, mm: int) -> datetime:
    return datetime(y, m, d, hh, mm, tzinfo=MARKET_TZ).astimezone(timezone.utc)


def make_brief(
    *,
    closes: Optional[Sequence[float]] = None,
    policy: Optional[RiskPolicy] = None,
    account: Optional[Account] = None,
    position: Optional[Position] = None,
    now: Optional[datetime] = None,
    market_open: Optional[bool] = True,
    quote_age_seconds: float = 1.0,
    exposure: Optional[PortfolioExposure] = None,
    peer_bars: Optional[dict] = None,
    symbol: str = "TEST",
) -> ResearchBrief:
    policy = policy or RiskPolicy()
    account = account or Account(
        account_number="PA_TEST",
        portfolio_value=100_000.0,
        buying_power=200_000.0,
        cash=100_000.0,
        equity=100_000.0,
        trading_blocked=False,
        pattern_day_trader=False,
    )
    now = now or et(2026, 3, 2, 10, 30)  # Monday, inside the session
    bars = make_bars(closes if closes is not None else flat_closes())
    last = bars[-1].close
    quote = Quote(
        ts=now - timedelta(seconds=quote_age_seconds),
        bid=last - 0.01,
        ask=last + 0.01,
    )
    clock = (
        None
        if market_open is None
        else MarketClock(timestamp=now, is_open=market_open, next_open=None, next_close=None)
    )
    return build_brief(
        symbol,
        provider=FixtureMarketData(bars, quote=quote),
        policy=policy,
        account=account,
        position=position,
        clock=clock,
        exposure=exposure,
        peer_bars=peer_bars,
        now=now,
    )
