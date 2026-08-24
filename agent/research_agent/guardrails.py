"""Deterministic enforcement of the trading rules.

The system prompt tells Claude the rules; this module assumes it might not have
followed them. Every hard rule in the spec is re-checked here against the same
research brief, and a decision that fails any check is rewritten as NO_TRADE.

The model proposes. This layer disposes.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional

from .config import RiskPolicy
from .research import ResearchBrief
from .schema import CONFIDENCE_RANK, TradeDecision, no_trade
from .sizing import SizingError, SizingPlan, plan_size


@dataclass
class GuardrailResult:
    decision: TradeDecision
    plan: Optional[SizingPlan] = None
    vetoes: list[str] = field(default_factory=list)
    adjustments: list[str] = field(default_factory=list)

    @property
    def approved(self) -> bool:
        return self.decision.decision in {"BUY", "SELL"} and not self.vetoes

    @property
    def was_overridden(self) -> bool:
        return bool(self.vetoes)


def _veto(
    proposed: TradeDecision, vetoes: list[str], adjustments: list[str]
) -> GuardrailResult:
    reasons = "; ".join(vetoes)
    original = (
        f"{proposed.decision}"
        + (f" {proposed.qty:g} {proposed.symbol}" if proposed.qty else "")
        + f" at {proposed.confidence} confidence"
    )
    reasoning = (
        f"Risk layer overrode the model to NO_TRADE: {reasons}. "
        f"The model had proposed {original}, reasoning: "
        f"{proposed.reasoning.strip()}"
    )
    return GuardrailResult(
        decision=no_trade(proposed.symbol, reasoning, confidence="LOW"),
        vetoes=vetoes,
        adjustments=adjustments,
    )


def review(
    proposed: TradeDecision,
    brief: ResearchBrief,
    policy: RiskPolicy,
    *,
    trading_blocked: bool = False,
    requested_symbol: Optional[str] = None,
) -> GuardrailResult:
    """Check a proposed decision against every hard rule. Never raises."""
    vetoes: list[str] = []
    adjustments: list[str] = []

    # A NO_TRADE needs no policing — it is already the safe default.
    if proposed.decision == "NO_TRADE":
        return GuardrailResult(decision=proposed)

    # Rule: only trade during regular market hours.
    if not brief.session.is_tradeable:
        vetoes.append(f"market is not in the regular session ({brief.session.detail})")

    if trading_blocked:
        vetoes.append("the brokerage account is flagged trading_blocked")

    # Rule: if uncertain, do not trade. Stale prices make sizing dishonest.
    quote_age = brief.quote.age_seconds(brief.generated_at)
    if quote_age > policy.max_quote_age_seconds:
        vetoes.append(
            f"quote is stale ({quote_age:.0f}s old, limit "
            f"{policy.max_quote_age_seconds}s)"
        )

    # The model must trade the instrument it was asked about.
    expected = (requested_symbol or brief.symbol).strip().upper()
    if proposed.symbol != expected:
        vetoes.append(
            f"model returned symbol {proposed.symbol!r} but the brief covers {expected!r}"
        )

    # Rule: if uncertain, the default action is NO_TRADE.
    if CONFIDENCE_RANK[proposed.confidence] < CONFIDENCE_RANK[policy.min_confidence]:
        vetoes.append(
            f"confidence {proposed.confidence} is below the required "
            f"{policy.min_confidence}"
        )

    # Rule: no trading at RSI extremes, absent a strong contrarian reason.
    zone = brief.rsi_zone(policy)
    if zone != "NEUTRAL":
        contrarian = (zone == "OVERBOUGHT" and proposed.decision == "SELL") or (
            zone == "OVERSOLD" and proposed.decision == "BUY"
        )
        if not contrarian:
            vetoes.append(
                f"RSI {brief.rsi:.1f} is {zone.lower()} and a {proposed.decision} "
                f"adds to that extreme rather than fading it"
            )
        elif not policy.allow_contrarian_override:
            vetoes.append(
                f"RSI {brief.rsi:.1f} is {zone.lower()} and contrarian overrides "
                "are disabled by policy"
            )
        elif proposed.confidence != "HIGH":
            vetoes.append(
                f"RSI {brief.rsi:.1f} is {zone.lower()}; a contrarian trade needs "
                f"HIGH confidence but the model gave {proposed.confidence}"
            )
        else:
            adjustments.append(
                f"allowed as a HIGH-confidence contrarian trade against "
                f"{zone.lower()} RSI {brief.rsi:.1f}"
            )

    # Rule: never risk more than 2% of portfolio value on a single trade.
    plan: Optional[SizingPlan] = None
    try:
        plan = plan_size(
            side="buy" if proposed.decision == "BUY" else "sell",
            entry_price=brief.reference_price,
            atr_value=brief.atr,
            portfolio_value=brief.portfolio_value,
            buying_power=brief.buying_power,
            policy=policy,
        )
    except SizingError as exc:
        vetoes.append(f"cannot size the position: {exc}")

    final_qty = proposed.qty
    if plan is not None:
        allowed = plan.max_qty

        # Adding to an existing position in the same direction consumes the same
        # concentration budget, so net it off before sizing the new clip.
        pos = brief.open_position
        if pos is not None and pos.qty != 0:
            same_way = (proposed.decision == "BUY" and pos.is_long) or (
                proposed.decision == "SELL" and pos.is_short
            )
            if same_way:
                room = allowed - abs(pos.qty)
                if room < allowed:
                    adjustments.append(
                        f"existing {abs(pos.qty):g}-share position consumes part of "
                        f"the cap; room for {max(room, 0):.0f} more"
                    )
                allowed = room

        allowed = int(max(allowed, 0))
        if allowed < 1:
            vetoes.append(
                f"risk limits leave room for 0 shares "
                f"(binding constraint: {plan.binding_constraint})"
            )
        elif proposed.qty is None or proposed.qty > allowed:
            adjustments.append(
                f"qty clamped from {proposed.qty if proposed.qty is not None else 'null'} "
                f"to {allowed} by the {plan.binding_constraint}"
            )
            final_qty = float(allowed)
        else:
            final_qty = float(int(proposed.qty))
            if final_qty < 1:
                vetoes.append("proposed qty rounds to 0 whole shares")

    if vetoes:
        return _veto(proposed, vetoes, adjustments)

    approved = TradeDecision(
        decision=proposed.decision,
        symbol=proposed.symbol,
        qty=final_qty,
        reasoning=proposed.reasoning,
        confidence=proposed.confidence,
    )
    return GuardrailResult(decision=approved, plan=plan, adjustments=adjustments)
