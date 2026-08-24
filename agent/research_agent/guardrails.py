"""Deterministic enforcement of the trading rules.

The system prompt tells Claude the rules; this module assumes it might not have
followed them. Every hard rule in the spec is re-checked here against the same
research brief, and a decision that fails any check is rewritten as NO_TRADE.

The model proposes. This layer disposes.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Optional

from .config import RiskPolicy
from .portfolio import candidate_cluster
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

    # A trade that runs against an open position takes risk off the book. Work
    # this out first: several rules below deliberately exempt it.
    pos = brief.open_position
    reducing = bool(
        pos is not None
        and pos.qty != 0
        and (
            (proposed.decision == "SELL" and pos.is_long)
            or (proposed.decision == "BUY" and pos.is_short)
        )
    )

    # Rule: stop opening risk once the day's loss limit is hit. Exits stay
    # available — the point is to stop digging, not to trap the account.
    if brief.drawdown is not None and brief.drawdown.halts_entries and not reducing:
        vetoes.append(
            f"daily drawdown kill-switch is tripped ({brief.drawdown.describe()})"
        )

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

    # A reducing trade is capped only by what is actually held: entry-side
    # limits must never stand between the account and the exit.
    plan: Optional[SizingPlan] = None
    final_qty = proposed.qty

    if reducing:
        held = int(abs(pos.qty))
        if proposed.qty is None or proposed.qty > held:
            adjustments.append(
                f"qty clamped from {proposed.qty if proposed.qty is not None else 'null'} "
                f"to {held}: cannot reduce more than the {held} shares held"
            )
            final_qty = float(held)
        else:
            final_qty = float(int(proposed.qty))
        if final_qty < 1:
            vetoes.append("proposed qty rounds to 0 whole shares")
    else:
        # Rule: never risk more than 2% of portfolio value on a single trade.
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

        if plan is not None:
            allowed = plan.max_qty
            binding = plan.binding_constraint

            # Rule: the whole book, not just this trade. Risk already committed
            # to open positions is subtracted before this one is sized.
            if brief.exposure is not None:
                headroom = brief.exposure.headroom(policy)
                by_portfolio = math.floor(headroom / plan.stop_distance)
                if by_portfolio < allowed:
                    allowed = by_portfolio
                    binding = "portfolio risk cap"
                    adjustments.append(
                        f"portfolio already risks "
                        f"{brief.exposure.total_risk:,.2f} "
                        f"({brief.exposure.risk_pct():.2%} of "
                        f"{policy.max_portfolio_risk_pct:.2%} cap); "
                        f"{headroom:,.2f} of risk budget left"
                    )

            # Rule: correlated positions share a budget. Six semiconductor
            # longs are closer to one bet than to six, so they are charged
            # against a single cluster cap rather than counted separately.
            if brief.exposure is not None:
                cluster = candidate_cluster(
                    expected,
                    1 if proposed.decision == "BUY" else -1,
                    brief.exposure,
                    brief.peer_bars,
                    policy,
                    brief.static_groups,
                )
                if cluster.members:
                    cluster_room = cluster.headroom(policy)
                    by_cluster = math.floor(cluster_room / plan.stop_distance)
                    if by_cluster < allowed:
                        allowed = by_cluster
                        binding = "correlation cluster cap"
                        adjustments.append(
                            f"correlated with {cluster.label_summary()}: "
                            f"{cluster.committed_risk:,.2f} already at risk in "
                            f"that cluster, {cluster_room:,.2f} of the "
                            f"{cluster.budget(policy):,.2f} cluster budget left"
                        )

            # Adding to an existing position in the same direction consumes the
            # same concentration budget, so net it off before sizing the clip.
            if pos is not None and pos.qty != 0:
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
                    f"(binding constraint: {binding})"
                )
            elif proposed.qty is None or proposed.qty > allowed:
                adjustments.append(
                    f"qty clamped from "
                    f"{proposed.qty if proposed.qty is not None else 'null'} "
                    f"to {allowed} by the {binding}"
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
