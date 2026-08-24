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
from typing import Optional, Sequence

from .broker import AlpacaBroker, OpenOrder, Position
from .config import RiskPolicy


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
