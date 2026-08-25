"""Turn a risk budget into a share count.

"Risk 2% of the portfolio" is meaningless without a stop: risk is
`qty x distance-to-stop`, not `qty x price`. This module fixes the stop at
`stop_atr_mult x ATR` and solves for the largest qty whose loss-at-stop stays
inside the budget, then applies two further ceilings (notional concentration
and available buying power).
"""

from __future__ import annotations

import math
from dataclasses import dataclass

from .config import RiskPolicy


class SizingError(ValueError):
    pass


@dataclass(frozen=True)
class SizingPlan:
    side: str
    entry_price: float
    stop_price: float
    take_profit_price: float
    stop_distance: float
    risk_budget: float
    max_qty: int
    risk_at_max_qty: float
    binding_constraint: str
    qty_by_risk: int
    qty_by_notional: int
    qty_by_buying_power: int

    def risk_for(self, qty: float) -> float:
        return qty * self.stop_distance


def plan_size(
    *,
    side: str,
    entry_price: float,
    atr_value: float,
    portfolio_value: float,
    buying_power: float,
    policy: RiskPolicy,
) -> SizingPlan:
    side = side.lower()
    if side not in {"buy", "sell"}:
        raise SizingError(f"side must be buy or sell, got {side!r}")
    if entry_price <= 0:
        raise SizingError(f"entry_price must be positive, got {entry_price}")
    if atr_value <= 0:
        raise SizingError(
            "ATR is zero or negative, so the stop distance is undefined and no "
            "position can be sized honestly"
        )
    if portfolio_value <= 0:
        raise SizingError(f"portfolio_value must be positive, got {portfolio_value}")

    stop_distance = policy.stop_atr_mult * atr_value
    risk_budget = portfolio_value * policy.max_risk_pct

    if side == "buy":
        stop_price = entry_price - stop_distance
        take_profit_price = entry_price + policy.take_profit_r * stop_distance
    else:
        stop_price = entry_price + stop_distance
        take_profit_price = entry_price - policy.take_profit_r * stop_distance

    if stop_price <= 0 or take_profit_price <= 0:
        raise SizingError(
            f"ATR ({atr_value:.4f}) is too wide relative to price "
            f"({entry_price:.2f}): the {side} stop/target would be non-positive"
        )

    qty_by_risk = math.floor(risk_budget / stop_distance)
    qty_by_notional = math.floor((portfolio_value * policy.max_position_pct) / entry_price)
    qty_by_buying_power = math.floor(max(buying_power, 0.0) / entry_price)

    candidates = {
        "risk budget (2% rule)": qty_by_risk,
        "position concentration cap": qty_by_notional,
        "buying power": qty_by_buying_power,
    }
    binding_constraint = min(candidates, key=lambda k: candidates[k])
    max_qty = max(min(candidates.values()), 0)

    return SizingPlan(
        side=side,
        entry_price=entry_price,
        stop_price=stop_price,
        take_profit_price=take_profit_price,
        stop_distance=stop_distance,
        risk_budget=risk_budget,
        max_qty=max_qty,
        risk_at_max_qty=max_qty * stop_distance,
        binding_constraint=binding_constraint,
        qty_by_risk=qty_by_risk,
        qty_by_notional=qty_by_notional,
        qty_by_buying_power=qty_by_buying_power,
    )
