"""Decide which symbols are worth spending a model call on.

Scanning more symbols multiplies the expensive part. A watchlist of fifty at a
fifteen-minute cadence is over 1,300 Claude calls a day, and sequentially it
takes longer than the interval it runs on.

Two cheap filters fix that, in order:

**Can any trade survive?** Most of the risk layer is deterministic. When the
kill-switch is tripped, or the book has no headroom, or the caps size the
position to zero shares, *no* answer the model could give would be executed. The
call can be skipped with nothing lost - and this is exact, not a heuristic.

**Which of the rest are interesting?** What is left is ranked so a fixed budget
of calls goes to the symbols that have actually moved. This part is a heuristic
for allocating attention, not a prediction: it decides who gets asked, never
what the answer is.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

from .config import RiskPolicy
from .killswitch import DrawdownState
from .research import ResearchBrief
from .sizing import SizingError, plan_size


@dataclass(frozen=True)
class Screened:
    symbol: str
    brief: ResearchBrief
    score: float
    skip_reason: Optional[str] = None

    @property
    def skipped(self) -> bool:
        return self.skip_reason is not None

    def describe(self) -> str:
        if self.skipped:
            return f"{self.symbol:<6} skip  {self.skip_reason}"
        return f"{self.symbol:<6} score {self.score:5.2f}"


def blocking_reason(
    brief: ResearchBrief,
    policy: RiskPolicy,
    *,
    drawdown: Optional[DrawdownState] = None,
) -> Optional[str]:
    """Why no trade in this symbol could survive the guardrails, or None.

    Only reasons that hold whatever the model answers. Anything that depends on
    the decision - RSI direction, confidence - is left to the guardrails, which
    see the actual answer.
    """
    if not brief.session.is_tradeable:
        return "market is not in the regular session"

    holds_position = brief.open_position is not None and brief.open_position.qty != 0

    # An exit is always permitted, so a held position always deserves the call.
    if holds_position:
        return None

    if drawdown is not None and drawdown.halts_entries:
        return "kill-switch tripped and no position to reduce"

    try:
        plan = plan_size(
            side="buy",
            entry_price=brief.reference_price,
            atr_value=brief.atr,
            portfolio_value=brief.portfolio_value,
            buying_power=brief.buying_power,
            policy=policy,
        )
    except SizingError as exc:
        return f"cannot be sized ({exc})"

    if plan.max_qty < 1:
        return f"risk limits allow 0 shares ({plan.binding_constraint})"

    if brief.exposure is not None:
        headroom = brief.exposure.headroom(policy)
        if headroom < plan.stop_distance:
            return (
                f"portfolio risk cap leaves no room "
                f"({headroom:,.2f} against a {plan.stop_distance:,.2f} stop)"
            )

    return None


def interest_score(brief: ResearchBrief) -> float:
    """How unusual is this symbol right now, in units it can be compared in.

    Movement measured in ATRs rather than percent, so a volatile name is not
    permanently more interesting than a quiet one, plus a bounded contribution
    from unusual volume. Deliberately crude: its only job is to order a queue.
    """
    score = 0.0

    if brief.atr > 0 and brief.change_1d is not None:
        move = abs(brief.change_1d) / 100.0 * brief.reference_price
        score += min(move / brief.atr, 5.0)

    if brief.avg_volume_20 and brief.avg_volume_20 > 0:
        score += 0.5 * min(brief.last_volume / brief.avg_volume_20, 3.0)

    return round(score, 4)


def screen(
    briefs: dict[str, ResearchBrief],
    policy: RiskPolicy,
    *,
    drawdown: Optional[DrawdownState] = None,
    budget: Optional[int] = None,
) -> tuple[list[Screened], list[Screened]]:
    """Split a watchlist into (worth asking, skipped), highest interest first."""
    candidates: list[Screened] = []
    skipped: list[Screened] = []

    for symbol, brief in briefs.items():
        reason = blocking_reason(brief, policy, drawdown=drawdown)
        if reason:
            skipped.append(Screened(symbol, brief, 0.0, reason))
        else:
            candidates.append(Screened(symbol, brief, interest_score(brief)))

    candidates.sort(key=lambda c: c.score, reverse=True)

    if budget is not None and budget >= 0 and len(candidates) > budget:
        overflow = candidates[budget:]
        candidates = candidates[:budget]
        skipped.extend(
            Screened(c.symbol, c.brief, c.score, f"outside this pass's budget of {budget}")
            for c in overflow
        )

    return candidates, skipped
