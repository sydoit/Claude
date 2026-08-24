import json

import pytest
from pydantic import ValidationError

from research_agent.schema import TradeDecision, no_trade


def test_serialises_to_exactly_the_specified_shape():
    d = TradeDecision(
        decision="BUY", symbol="NVDA", qty=12, reasoning="Because.", confidence="HIGH"
    )
    payload = json.loads(d.to_json())
    assert list(payload) == ["decision", "symbol", "qty", "reasoning", "confidence"]
    assert payload == {
        "decision": "BUY", "symbol": "NVDA", "qty": 12.0,
        "reasoning": "Because.", "confidence": "HIGH",
    }


def test_no_trade_serialises_nulls_not_omissions():
    payload = json.loads(no_trade("AAPL", "Market closed.").to_json())
    assert payload["qty"] is None
    assert payload["decision"] == "NO_TRADE"


def test_symbol_is_normalised_to_upper_case():
    d = TradeDecision(decision="BUY", symbol=" nvda ", qty=1, reasoning="x", confidence="LOW")
    assert d.symbol == "NVDA"


def test_no_trade_drops_any_quantity():
    d = TradeDecision(decision="NO_TRADE", symbol="A", qty=50, reasoning="x", confidence="LOW")
    assert d.qty is None


@pytest.mark.parametrize(
    "kwargs",
    [
        dict(decision="BUY", symbol=None, qty=5, reasoning="x", confidence="LOW"),
        dict(decision="SELL", symbol="A", qty=0, reasoning="x", confidence="LOW"),
        dict(decision="BUY", symbol="A", qty=None, reasoning="x", confidence="LOW"),
        dict(decision="BUY", symbol="A", qty=-5, reasoning="x", confidence="LOW"),
        dict(decision="HOLD", symbol="A", qty=1, reasoning="x", confidence="LOW"),
        dict(decision="BUY", symbol="A", qty=1, reasoning="", confidence="LOW"),
        dict(decision="BUY", symbol="A", qty=1, reasoning="x", confidence="VERY_HIGH"),
    ],
)
def test_incoherent_decisions_are_rejected(kwargs):
    with pytest.raises(ValidationError):
        TradeDecision(**kwargs)


def test_extra_fields_are_rejected():
    with pytest.raises(ValidationError):
        TradeDecision(
            decision="NO_TRADE", symbol=None, qty=None, reasoning="x",
            confidence="LOW", stop_loss=99.0,
        )


def test_flat_converts_to_no_trade_keeping_the_symbol():
    d = TradeDecision(decision="BUY", symbol="A", qty=5, reasoning="x", confidence="HIGH")
    assert d.flat().decision == "NO_TRADE"
    assert d.flat().symbol == "A"
    assert d.flat().qty is None
