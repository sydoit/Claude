"""Which open positions actually fail together.

A per-symbol risk cap treats six semiconductor longs as six independent 1%
bets. They are closer to one 6% bet. This module measures how positions move
together so `portfolio` can charge correlated exposure against a shared budget.

The measure that matters is correlation of *signed exposure*, not of price. Two
symbols correlated +0.9 held in opposite directions hedge each other; the same
pair held the same way is one trade wearing two tickers. So every correlation is
multiplied by the product of the position directions before it is judged.

Where correlation cannot be measured - too little overlapping history, a
flat series, a symbol whose bars will not load - the pair is treated as
correlated. Diversification is a claim that has to be earned, and an
unmeasurable pair has not earned it.
"""

from __future__ import annotations

import json
import math
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping, Optional, Sequence

from .indicators import Bar

UNMEASURABLE = "unmeasurable"
MEASURED = "measured"
STATIC_GROUP = "static group"
SAME_SYMBOL = "same symbol"


def sign(x: float) -> int:
    return 1 if x > 0 else (-1 if x < 0 else 0)


def returns(bars: Sequence[Bar]) -> list[float]:
    out: list[float] = []
    for i in range(1, len(bars)):
        prev = bars[i - 1].close
        if prev == 0:
            out.append(0.0)
        else:
            out.append((bars[i].close - prev) / prev)
    return out


def aligned_returns(
    bars_a: Sequence[Bar], bars_b: Sequence[Bar]
) -> tuple[list[float], list[float]]:
    """Return series restricted to the sessions both symbols actually traded."""
    by_day_a = {b.ts.date(): b for b in bars_a}
    by_day_b = {b.ts.date(): b for b in bars_b}
    shared = sorted(set(by_day_a) & set(by_day_b))
    if len(shared) < 2:
        return [], []
    return (
        returns([by_day_a[d] for d in shared]),
        returns([by_day_b[d] for d in shared]),
    )


def pearson(a: Sequence[float], b: Sequence[float]) -> Optional[float]:
    """Pearson correlation, or None when it is undefined."""
    n = min(len(a), len(b))
    if n < 2:
        return None
    a, b = list(a[:n]), list(b[:n])
    mean_a, mean_b = sum(a) / n, sum(b) / n
    da = [x - mean_a for x in a]
    db = [y - mean_b for y in b]
    var_a = sum(x * x for x in da)
    var_b = sum(y * y for y in db)
    if var_a <= 0 or var_b <= 0:  # a flat series correlates with nothing
        return None
    value = sum(x * y for x, y in zip(da, db)) / math.sqrt(var_a * var_b)
    return max(-1.0, min(1.0, value))


@dataclass(frozen=True)
class CorrelationResult:
    symbol_a: str
    symbol_b: str
    value: Optional[float]
    basis: str
    observations: int = 0

    @property
    def measurable(self) -> bool:
        return self.value is not None

    def effective(self, qty_a: float, qty_b: float) -> Optional[float]:
        """Correlation adjusted for the direction each position is held."""
        if self.value is None:
            return None
        direction = sign(qty_a) * sign(qty_b)
        if direction == 0:
            return 0.0
        return self.value * direction

    def describe(self, qty_a: float, qty_b: float) -> str:
        eff = self.effective(qty_a, qty_b)
        if eff is None:
            return f"{self.symbol_a}/{self.symbol_b}: {self.basis}, treated as correlated"
        return (
            f"{self.symbol_a}/{self.symbol_b}: {eff:+.2f} "
            f"({self.basis}, {self.observations} obs)"
        )


def load_static_groups(path: str | Path | None = None) -> dict[str, str]:
    """Read an optional {"group": ["SYM", ...]} file into symbol -> group.

    Use it for relationships too new or too thin to measure. An empty mapping
    (the default) means correlation is decided entirely by the data.
    """
    path = path or os.getenv("CORRELATION_GROUPS_FILE")
    if not path:
        return {}
    p = Path(path)
    if not p.exists():
        return {}
    raw = json.loads(p.read_text())
    mapping: dict[str, str] = {}
    for group, symbols in raw.items():
        for symbol in symbols:
            mapping[str(symbol).strip().upper()] = str(group)
    return mapping


def measure(
    symbol_a: str,
    bars_a: Optional[Sequence[Bar]],
    symbol_b: str,
    bars_b: Optional[Sequence[Bar]],
    *,
    lookback: int = 60,
    min_observations: int = 20,
    static_groups: Optional[Mapping[str, str]] = None,
) -> CorrelationResult:
    symbol_a, symbol_b = symbol_a.upper(), symbol_b.upper()

    if symbol_a == symbol_b:
        return CorrelationResult(symbol_a, symbol_b, 1.0, SAME_SYMBOL)

    groups = static_groups or {}
    group_a, group_b = groups.get(symbol_a), groups.get(symbol_b)
    if group_a is not None and group_a == group_b:
        return CorrelationResult(symbol_a, symbol_b, 1.0, f"{STATIC_GROUP} {group_a!r}")

    if not bars_a or not bars_b:
        return CorrelationResult(symbol_a, symbol_b, None, "no price history")

    ra, rb = aligned_returns(list(bars_a)[-(lookback + 1):], list(bars_b)[-(lookback + 1):])
    if len(ra) < min_observations:
        return CorrelationResult(
            symbol_a, symbol_b, None,
            f"only {len(ra)} overlapping sessions, need {min_observations}",
            observations=len(ra),
        )

    value = pearson(ra, rb)
    if value is None:
        return CorrelationResult(
            symbol_a, symbol_b, None, "flat return series", observations=len(ra)
        )
    return CorrelationResult(symbol_a, symbol_b, value, MEASURED, observations=len(ra))


def clusters_together(
    result: CorrelationResult, qty_a: float, qty_b: float, threshold: float
) -> bool:
    """Do these two positions belong to one risk cluster?"""
    effective = result.effective(qty_a, qty_b)
    if effective is None:
        return True  # unmeasurable: assume the worst
    return effective >= threshold
