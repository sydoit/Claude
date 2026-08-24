"""Carry out an approved decision against the brokerage account.

Reconciles the decision with whatever position is already open, so a SELL on a
long book means "get out", not "flip short".
"""

from __future__ import annotations

import hashlib
import logging
from dataclasses import dataclass
from typing import Optional

from .broker import AlpacaBroker, LiveTradingBlocked, OrderResult
from .research import ResearchBrief
from .schema import TradeDecision
from .sizing import SizingPlan

log = logging.getLogger(__name__)


@dataclass
class ExecutionReport:
    action: str  # opened | added | reduced | closed | skipped | failed
    intent: str
    order: Optional[OrderResult] = None
    dry_run: bool = False
    error: Optional[str] = None

    @property
    def submitted(self) -> bool:
        return self.order is not None


def client_order_id(decision: TradeDecision, brief: ResearchBrief, qty: float) -> str:
    """Deterministic per (symbol, side, qty, minute).

    Alpaca rejects a duplicate client_order_id, which turns an accidental
    double-run inside the same minute into a no-op instead of a double position.
    """
    stamp = brief.generated_at.strftime("%Y%m%d%H%M")
    seed = f"{brief.symbol}:{decision.decision}:{qty:g}:{stamp}"
    digest = hashlib.sha1(seed.encode()).hexdigest()[:10]
    return f"mra-{brief.symbol.lower()}-{stamp}-{digest}"


def execute(
    decision: TradeDecision,
    plan: Optional[SizingPlan],
    brief: ResearchBrief,
    broker: AlpacaBroker,
    *,
    dry_run: bool = True,
) -> ExecutionReport:
    if decision.decision == "NO_TRADE" or not decision.qty:
        return ExecutionReport(action="skipped", intent="no trade to place")

    qty = int(decision.qty)
    pos = brief.open_position
    held = pos.qty if pos else 0.0

    # Closing first: if the decision runs against an open position, reduce it
    # rather than opening opposing exposure.
    closing_side: Optional[str] = None
    if decision.decision == "SELL" and held > 0:
        closing_side = "sell"
    elif decision.decision == "BUY" and held < 0:
        closing_side = "buy"

    if closing_side:
        close_qty = min(qty, int(abs(held)))
        if close_qty < 1:
            return ExecutionReport(action="skipped", intent="nothing to reduce")
        intent = (
            f"{closing_side.upper()} {close_qty} {brief.symbol} to reduce an open "
            f"{'long' if held > 0 else 'short'} of {abs(held):g}"
        )
        if dry_run:
            return ExecutionReport(action="reduced", intent=intent, dry_run=True)
        try:
            order = broker.submit_closing_order(
                symbol=brief.symbol,
                qty=close_qty,
                side=closing_side,
                client_order_id=client_order_id(decision, brief, close_qty),
            )
        except LiveTradingBlocked:
            # A safety refusal is not an order failure: let it reach the operator.
            raise
        except Exception as exc:  # surfaced to the operator, never swallowed
            log.error("closing order failed: %s", exc)
            return ExecutionReport(action="failed", intent=intent, error=str(exc))
        action = "closed" if close_qty >= abs(held) else "reduced"
        return ExecutionReport(action=action, intent=intent, order=order)

    # Opening or adding, with the protective stop attached.
    if plan is None:
        return ExecutionReport(
            action="failed",
            intent="open a position",
            error="no sizing plan available, refusing to submit an unprotected order",
        )

    side = "buy" if decision.decision == "BUY" else "sell"
    intent = (
        f"{side.upper()} {qty} {brief.symbol} @ ~{plan.entry_price:,.2f}, "
        f"stop {plan.stop_price:,.2f}, target {plan.take_profit_price:,.2f} "
        f"(risk {plan.risk_for(qty):,.2f} = "
        f"{plan.risk_for(qty) / brief.portfolio_value:.2%} of portfolio)"
    )
    if dry_run:
        return ExecutionReport(action="opened", intent=intent, dry_run=True)

    try:
        order = broker.submit_bracket_order(
            symbol=brief.symbol,
            qty=qty,
            side=side,
            stop_price=plan.stop_price,
            take_profit_price=plan.take_profit_price,
            client_order_id=client_order_id(decision, brief, qty),
        )
    except LiveTradingBlocked:
        raise
    except Exception as exc:
        log.error("bracket order failed: %s", exc)
        return ExecutionReport(action="failed", intent=intent, error=str(exc))

    return ExecutionReport(
        action="added" if held else "opened", intent=intent, order=order
    )
