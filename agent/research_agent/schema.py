"""The output contract. Exactly the five fields the spec asks for, nothing else."""

from __future__ import annotations

import json
from typing import Literal, Optional

from pydantic import BaseModel, Field, field_validator, model_validator

Decision = Literal["BUY", "SELL", "NO_TRADE"]
Confidence = Literal["LOW", "MEDIUM", "HIGH"]

CONFIDENCE_RANK = {"LOW": 0, "MEDIUM": 1, "HIGH": 2}


class TradeDecision(BaseModel):
    """The agent's answer.

    Serialises to exactly:
        {"decision": ..., "symbol": ..., "qty": ..., "reasoning": ..., "confidence": ...}
    """

    decision: Decision
    symbol: Optional[str] = None
    qty: Optional[float] = None
    reasoning: str = Field(min_length=1)
    confidence: Confidence

    model_config = {"extra": "forbid"}

    @field_validator("symbol")
    @classmethod
    def _upper(cls, v: Optional[str]) -> Optional[str]:
        if v is None:
            return None
        v = v.strip().upper()
        return v or None

    @field_validator("qty")
    @classmethod
    def _qty_sane(cls, v: Optional[float]) -> Optional[float]:
        if v is None:
            return None
        if v < 0:
            raise ValueError("qty must not be negative; use decision=SELL to go short")
        return v

    @model_validator(mode="after")
    def _coherent(self) -> "TradeDecision":
        if self.decision == "NO_TRADE":
            # A no-trade carries no size. Symbol may stay for context.
            object.__setattr__(self, "qty", None)
        else:
            if not self.symbol:
                raise ValueError(f"decision={self.decision} requires a symbol")
            if self.qty is None or self.qty <= 0:
                raise ValueError(f"decision={self.decision} requires a positive qty")
        return self

    def to_json(self, indent: int | None = 2) -> str:
        return json.dumps(self.model_dump(), indent=indent)

    def flat(self) -> "TradeDecision":
        """Convert this decision into a NO_TRADE while keeping the symbol."""
        return TradeDecision(
            decision="NO_TRADE",
            symbol=self.symbol,
            qty=None,
            reasoning=self.reasoning,
            confidence=self.confidence,
        )


def no_trade(symbol: Optional[str], reasoning: str, confidence: Confidence = "LOW") -> TradeDecision:
    """The default answer whenever anything is uncertain."""
    return TradeDecision(
        decision="NO_TRADE",
        symbol=symbol,
        qty=None,
        reasoning=reasoning,
        confidence=confidence,
    )
