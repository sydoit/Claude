"""The reasoning step: hand the brief to Claude, get a structured decision back."""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Optional

import anthropic

from .config import AgentSettings
from .prompt import system_prompt, user_message
from .research import ResearchBrief
from .schema import TradeDecision, no_trade

log = logging.getLogger(__name__)


@dataclass
class ModelOutcome:
    decision: TradeDecision
    raw_stop_reason: Optional[str] = None
    error: Optional[str] = None

    @property
    def failed(self) -> bool:
        return self.error is not None


def propose_decision(
    brief: ResearchBrief,
    settings: AgentSettings,
    *,
    client: Optional[anthropic.Anthropic] = None,
) -> ModelOutcome:
    """Ask Claude for a decision.

    Any failure — API error, refusal, schema violation — resolves to NO_TRADE.
    That is the spec's uncertainty rule applied to the infrastructure itself:
    a bot that cannot think clearly must not trade.
    """
    client = client or anthropic.Anthropic()
    policy = settings.risk

    try:
        response = client.messages.parse(
            model=settings.model,
            max_tokens=settings.max_tokens,
            system=system_prompt(policy),
            thinking={"type": "adaptive"},
            output_config={"effort": settings.effort},
            output_format=TradeDecision,
            messages=[{"role": "user", "content": user_message(brief, policy)}],
        )
    except anthropic.APIStatusError as exc:
        log.warning("Claude API error: %s", exc)
        return ModelOutcome(
            decision=no_trade(
                brief.symbol,
                f"No decision was made: the reasoning model returned an API error "
                f"(HTTP {exc.status_code}). Defaulting to NO_TRADE because an "
                f"unanswered question is an uncertain one.",
            ),
            error=str(exc),
        )
    except anthropic.APIConnectionError as exc:
        log.warning("Claude connection error: %s", exc)
        return ModelOutcome(
            decision=no_trade(
                brief.symbol,
                "No decision was made: could not reach the reasoning model. "
                "Defaulting to NO_TRADE.",
            ),
            error=str(exc),
        )

    if response.stop_reason == "refusal":
        return ModelOutcome(
            decision=no_trade(
                brief.symbol,
                "The reasoning model declined to answer this request, so no "
                "trade is placed.",
            ),
            raw_stop_reason=response.stop_reason,
            error="refusal",
        )

    parsed = getattr(response, "parsed_output", None)
    if parsed is None:
        return ModelOutcome(
            decision=no_trade(
                brief.symbol,
                "The reasoning model did not return a decision in the required "
                "format, so no trade is placed.",
            ),
            raw_stop_reason=response.stop_reason,
            error="unparseable output",
        )

    return ModelOutcome(decision=parsed, raw_stop_reason=response.stop_reason)
