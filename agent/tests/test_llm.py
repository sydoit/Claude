"""The reasoning step must never be the thing that places a trade by accident."""

from __future__ import annotations

import anthropic
import httpx2
import pytest

from research_agent.config import AgentSettings
from research_agent.llm import propose_decision
from tests.conftest import make_brief


class FakeClient:
    def __init__(self, error=None, response=None):
        self._error = error
        self._response = response
        self.messages = self

    def parse(self, **kwargs):
        if self._error:
            raise self._error
        return self._response


class FakeResponse:
    def __init__(self, stop_reason="end_turn", parsed_output=None):
        self.stop_reason = stop_reason
        self.parsed_output = parsed_output


def outcome_for(client):
    return propose_decision(make_brief(), AgentSettings(), client=client)


def test_a_missing_api_key_yields_no_trade_not_a_crash():
    """An unresolvable key raises before any request is built."""
    error = TypeError("Could not resolve authentication method.")
    result = outcome_for(FakeClient(error=error))
    assert result.failed
    assert result.decision.decision == "NO_TRADE"
    assert "TypeError" in result.error


def test_an_api_error_yields_no_trade():
    request = httpx2.Request("POST", "https://api.anthropic.com/v1/messages")
    error = anthropic.APIStatusError(
        "boom", response=httpx2.Response(500, request=request), body=None
    )
    result = outcome_for(FakeClient(error=error))
    assert result.decision.decision == "NO_TRADE"
    assert "HTTP 500" in result.decision.reasoning


def test_a_connection_error_yields_no_trade():
    request = httpx2.Request("POST", "https://api.anthropic.com/v1/messages")
    error = anthropic.APIConnectionError(request=request)
    result = outcome_for(FakeClient(error=error))
    assert result.decision.decision == "NO_TRADE"
    assert "could not reach" in result.decision.reasoning


def test_a_refusal_yields_no_trade():
    result = outcome_for(FakeClient(response=FakeResponse(stop_reason="refusal")))
    assert result.decision.decision == "NO_TRADE"
    assert result.error == "refusal"


def test_an_unparseable_response_yields_no_trade():
    result = outcome_for(FakeClient(response=FakeResponse(parsed_output=None)))
    assert result.decision.decision == "NO_TRADE"
    assert "required" in result.decision.reasoning


def test_every_failure_path_is_low_confidence():
    for client in (
        FakeClient(error=TypeError("x")),
        FakeClient(response=FakeResponse(stop_reason="refusal")),
        FakeClient(response=FakeResponse(parsed_output=None)),
    ):
        assert outcome_for(client).decision.confidence == "LOW"


def test_a_good_response_passes_through():
    from research_agent.schema import TradeDecision

    decision = TradeDecision(
        decision="BUY", symbol="TEST", qty=5, reasoning="ok", confidence="HIGH"
    )
    result = outcome_for(FakeClient(response=FakeResponse(parsed_output=decision)))
    assert not result.failed
    assert result.decision is decision
