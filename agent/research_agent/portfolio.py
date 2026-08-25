"""Portfolio-level risk: how much of the account is already at stake.

The per-trade 2% cap says nothing about how many trades are open at once. Ten
positions each risking 2% is 20% of the account on the table. This module
measures what is already live so `guardrails` can refuse the eleventh.

Risk on an open position is measured the same way it is measured when sizing a
new one: distance from the current price to the protective stop, times the
share count. A position with no working stop has no measurable floor, so its
whole notional is counted as at risk — which is both the honest reading and a
strong incentive to keep stops attached.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Mapping, Optional, Sequence

from .broker import AlpacaBroker, OpenOrder, Position
from .config import RiskPolicy
from .correlation import (
    CorrelationResult,
    clusters_together,
    measure,
    sign,
)
from .indicators import Bar


@dataclass(frozen=True)
class PositionRisk:
    symbol: str
    qty: float
    price: float
    stop_price: Optional[float]
    risk_amount: float

    @property
    def is_protected(self) -> bool:
        return self.stop_price is not None

    def describe(self) -> str:
        side = "LONG" if self.qty > 0 else "SHORT"
        if self.stop_price is None:
            return (
                f"{side} {abs(self.qty):g} {self.symbol} @ {self.price:,.2f} "
                f"- NO STOP, full notional {self.risk_amount:,.2f} counted as at risk"
            )
        return (
            f"{side} {abs(self.qty):g} {self.symbol} @ {self.price:,.2f}, "
            f"stop {self.stop_price:,.2f} -> {self.risk_amount:,.2f} at risk"
        )


@dataclass(frozen=True)
class PortfolioExposure:
    positions: Sequence[PositionRisk] = field(default_factory=tuple)
    portfolio_value: float = 0.0

    @property
    def total_risk(self) -> float:
        return sum(p.risk_amount for p in self.positions)

    @property
    def unprotected(self) -> list[PositionRisk]:
        return [p for p in self.positions if not p.is_protected]

    def risk_pct(self) -> float:
        if self.portfolio_value <= 0:
            return 0.0
        return self.total_risk / self.portfolio_value

    def budget(self, policy: RiskPolicy) -> float:
        return self.portfolio_value * policy.max_portfolio_risk_pct

    def headroom(self, policy: RiskPolicy, *, exclude_symbol: Optional[str] = None) -> float:
        """Risk budget still available for a new trade, never negative.

        `exclude_symbol` drops an existing position from the total when the new
        trade replaces rather than adds to it.
        """
        committed = sum(
            p.risk_amount
            for p in self.positions
            if exclude_symbol is None or p.symbol != exclude_symbol
        )
        return max(self.budget(policy) - committed, 0.0)

    def describe(self, policy: RiskPolicy) -> list[str]:
        if not self.positions:
            return ["  (no open positions)"]
        lines = [f"  - {p.describe()}" for p in self.positions]
        lines.append(
            f"  Total at risk: {self.total_risk:,.2f} "
            f"({self.risk_pct():.2%} of portfolio; cap "
            f"{policy.max_portfolio_risk_pct:.2%} = {self.budget(policy):,.2f})"
        )
        return lines


def stop_for(symbol: str, position: Position, orders: Sequence[OpenOrder]) -> Optional[float]:
    """Find the working stop protecting a position.

    The protective stop trades in the opposite direction to the position, so a
    long is guarded by a sell-stop and a short by a buy-stop. Where several
    exist, the tightest one is the floor that actually binds.
    """
    wanted_side = "sell" if position.qty > 0 else "buy"
    candidates = [
        o.stop_price
        for o in orders
        if o.symbol == symbol
        and o.is_stop
        and o.side == wanted_side
        and o.stop_price is not None
    ]
    if not candidates:
        return None
    # Tightest stop = highest for a long, lowest for a short.
    return max(candidates) if position.qty > 0 else min(candidates)


def measure_position(position: Position, orders: Sequence[OpenOrder]) -> PositionRisk:
    price = position.price
    stop = stop_for(position.symbol, position, orders)
    qty = abs(position.qty)

    if stop is None:
        risk = qty * price  # no floor, so the whole position is exposed
    elif position.qty > 0:
        risk = qty * max(price - stop, 0.0)
    else:
        risk = qty * max(stop - price, 0.0)

    return PositionRisk(
        symbol=position.symbol,
        qty=position.qty,
        price=price,
        stop_price=stop,
        risk_amount=risk,
    )


def assess(
    positions: Sequence[Position],
    orders: Sequence[OpenOrder],
    portfolio_value: float,
) -> PortfolioExposure:
    return PortfolioExposure(
        positions=tuple(
            measure_position(p, orders) for p in positions if p.qty != 0
        ),
        portfolio_value=portfolio_value,
    )


def assess_from_broker(broker: AlpacaBroker, portfolio_value: float) -> PortfolioExposure:
    return assess(broker.positions(), broker.open_orders(), portfolio_value)


# --- correlation clusters -----------------------------------------------------


@dataclass(frozen=True)
class RiskCluster:
    """Positions that move together, and therefore fail together."""

    members: tuple[PositionRisk, ...]
    notes: tuple[str, ...] = ()

    @property
    def label(self) -> str:
        return "+".join(p.symbol for p in self.members)

    @property
    def total_risk(self) -> float:
        return sum(p.risk_amount for p in self.members)

    def describe(self, portfolio_value: float, policy: RiskPolicy) -> str:
        pct = self.total_risk / portfolio_value if portfolio_value > 0 else 0.0
        over = " OVER CAP" if pct > policy.max_cluster_risk_pct else ""
        return (
            f"{self.label}: {self.total_risk:,.2f} at risk "
            f"({pct:.2%} of the {policy.max_cluster_risk_pct:.2%} "
            f"cluster cap){over}"
        )


@dataclass(frozen=True)
class CandidateCluster:
    """Everything on the book that a proposed trade would compound."""

    symbol: str
    members: tuple[PositionRisk, ...]
    correlations: tuple[CorrelationResult, ...]
    notes: tuple[str, ...]
    portfolio_value: float

    @property
    def committed_risk(self) -> float:
        return sum(p.risk_amount for p in self.members)

    def label_summary(self) -> str:
        return ", ".join(p.symbol for p in self.members) or "nothing"

    def budget(self, policy: RiskPolicy) -> float:
        return self.portfolio_value * policy.max_cluster_risk_pct

    def headroom(self, policy: RiskPolicy) -> float:
        return max(self.budget(policy) - self.committed_risk, 0.0)

    def describe(self, policy: RiskPolicy) -> list[str]:
        if not self.members:
            return [f"  {self.symbol} is uncorrelated with anything currently open"]
        lines = [
            f"  {self.symbol} would compound "
            f"{len(self.members)} open position(s):"
        ]
        lines += [f"    - {n}" for n in self.notes]
        lines.append(
            f"  Cluster risk if this trade is added: "
            f"{self.committed_risk:,.2f} committed, "
            f"{self.headroom(policy):,.2f} of the "
            f"{self.budget(policy):,.2f} cluster budget left"
        )
        return lines


def _pairwise(
    symbol_a: str,
    symbol_b: str,
    bars: Mapping[str, Sequence[Bar]],
    policy: RiskPolicy,
    static_groups: Optional[Mapping[str, str]],
) -> CorrelationResult:
    return measure(
        symbol_a,
        bars.get(symbol_a.upper()),
        symbol_b,
        bars.get(symbol_b.upper()),
        lookback=policy.correlation_lookback,
        min_observations=policy.correlation_min_observations,
        static_groups=static_groups,
    )


def candidate_cluster(
    symbol: str,
    direction: int,
    exposure: PortfolioExposure,
    bars: Mapping[str, Sequence[Bar]],
    policy: RiskPolicy,
    static_groups: Optional[Mapping[str, str]] = None,
) -> CandidateCluster:
    """Find the open positions a proposed trade would stack on top of.

    `direction` is +1 for a BUY and -1 for a SELL: a trade only compounds a
    position it would move in sympathy with.
    """
    symbol = symbol.upper()
    members: list[PositionRisk] = []
    results: list[CorrelationResult] = []
    notes: list[str] = []

    for position in exposure.positions:
        result = _pairwise(symbol, position.symbol, bars, policy, static_groups)
        if clusters_together(result, direction, position.qty, policy.correlation_threshold):
            members.append(position)
            results.append(result)
            notes.append(
                f"{result.describe(direction, position.qty)} - "
                f"{position.risk_amount:,.2f} at risk"
            )

    return CandidateCluster(
        symbol=symbol,
        members=tuple(members),
        correlations=tuple(results),
        notes=tuple(notes),
        portfolio_value=exposure.portfolio_value,
    )


def cluster_book(
    exposure: PortfolioExposure,
    bars: Mapping[str, Sequence[Bar]],
    policy: RiskPolicy,
    static_groups: Optional[Mapping[str, str]] = None,
) -> list[RiskCluster]:
    """Group open positions into clusters that move together.

    Single-linkage: if A clusters with B and B with C, all three are one
    cluster even when A and C are not directly correlated. That over-groups
    rather than under-groups, which is the safe direction for a risk cap.
    """
    positions = list(exposure.positions)
    parent = list(range(len(positions)))

    def find(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    def union(i: int, j: int) -> None:
        ri, rj = find(i), find(j)
        if ri != rj:
            parent[rj] = ri

    notes: dict[int, list[str]] = {}
    for i in range(len(positions)):
        for j in range(i + 1, len(positions)):
            a, b = positions[i], positions[j]
            result = _pairwise(a.symbol, b.symbol, bars, policy, static_groups)
            if clusters_together(result, a.qty, b.qty, policy.correlation_threshold):
                union(i, j)
                notes.setdefault(find(i), []).append(result.describe(a.qty, b.qty))

    grouped: dict[int, list[PositionRisk]] = {}
    for idx, position in enumerate(positions):
        grouped.setdefault(find(idx), []).append(position)

    return [
        RiskCluster(members=tuple(members), notes=tuple(notes.get(root, ())))
        for root, members in grouped.items()
    ]
