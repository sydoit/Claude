"""Indicator math. Wilder smoothing, computed from bars, no third-party TA dep."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Sequence


class InsufficientData(ValueError):
    """Not enough bars to compute an indicator honestly."""


@dataclass(frozen=True)
class Bar:
    ts: datetime
    open: float
    high: float
    low: float
    close: float
    volume: float


def _closes(bars: Sequence[Bar]) -> list[float]:
    return [b.close for b in bars]


def rsi(bars: Sequence[Bar], period: int = 14) -> float:
    """Wilder's RSI over closing prices.

    Needs period + 1 bars: `period` price changes to seed the averages.
    """
    if period < 2:
        raise ValueError("period must be >= 2")
    closes = _closes(bars)
    if len(closes) < period + 1:
        raise InsufficientData(
            f"RSI({period}) needs {period + 1} bars, got {len(closes)}"
        )

    deltas = [closes[i] - closes[i - 1] for i in range(1, len(closes))]
    gains = [max(d, 0.0) for d in deltas]
    losses = [max(-d, 0.0) for d in deltas]

    avg_gain = sum(gains[:period]) / period
    avg_loss = sum(losses[:period]) / period
    for i in range(period, len(deltas)):
        avg_gain = (avg_gain * (period - 1) + gains[i]) / period
        avg_loss = (avg_loss * (period - 1) + losses[i]) / period

    if avg_loss == 0:
        return 100.0 if avg_gain > 0 else 50.0
    rs = avg_gain / avg_loss
    return 100.0 - (100.0 / (1.0 + rs))


def true_ranges(bars: Sequence[Bar]) -> list[float]:
    out: list[float] = []
    for i in range(1, len(bars)):
        cur, prev = bars[i], bars[i - 1]
        out.append(
            max(
                cur.high - cur.low,
                abs(cur.high - prev.close),
                abs(cur.low - prev.close),
            )
        )
    return out


def atr(bars: Sequence[Bar], period: int = 14) -> float:
    """Wilder's Average True Range. This sets the stop distance, so it sets size."""
    if period < 2:
        raise ValueError("period must be >= 2")
    if len(bars) < period + 1:
        raise InsufficientData(f"ATR({period}) needs {period + 1} bars, got {len(bars)}")

    trs = true_ranges(bars)
    value = sum(trs[:period]) / period
    for i in range(period, len(trs)):
        value = (value * (period - 1) + trs[i]) / period
    return value


def sma(bars: Sequence[Bar], period: int) -> float:
    closes = _closes(bars)
    if len(closes) < period:
        raise InsufficientData(f"SMA({period}) needs {period} bars, got {len(closes)}")
    return sum(closes[-period:]) / period


def ema(bars: Sequence[Bar], period: int) -> float:
    closes = _closes(bars)
    if len(closes) < period:
        raise InsufficientData(f"EMA({period}) needs {period} bars, got {len(closes)}")
    k = 2.0 / (period + 1)
    value = sum(closes[:period]) / period
    for price in closes[period:]:
        value = price * k + value * (1 - k)
    return value


def pct_change(bars: Sequence[Bar], lookback: int) -> float:
    closes = _closes(bars)
    if len(closes) < lookback + 1:
        raise InsufficientData(f"need {lookback + 1} bars, got {len(closes)}")
    past = closes[-(lookback + 1)]
    if past == 0:
        raise InsufficientData("cannot compute percent change from a zero price")
    return (closes[-1] - past) / past * 100.0
