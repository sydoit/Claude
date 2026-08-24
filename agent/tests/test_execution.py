import pytest

from research_agent.broker import AlpacaBroker, LiveTradingBlocked, Position
from research_agent.config import AgentSettings, AlpacaSettings
from research_agent.execution import client_order_id, execute
from research_agent.guardrails import review
from research_agent.schema import TradeDecision, no_trade
from tests.conftest import make_brief


class FakeHTTP:
    """Records order submissions instead of sending them."""

    def __init__(self):
        self.posted = []

    def trading_post(self, path, json_body):
        self.posted.append((path, json_body))
        return {
            "id": "order-1",
            "client_order_id": json_body.get("client_order_id", ""),
            "symbol": json_body["symbol"],
            "side": json_body["side"],
            "qty": json_body["qty"],
            "order_class": json_body.get("order_class", "simple"),
            "status": "accepted",
        }


def make_broker(trading_base_url="https://paper-api.alpaca.markets", allow_live=False):
    http = FakeHTTP()
    settings = AgentSettings(
        alpaca=AlpacaSettings(
            key_id="k", secret_key="s", trading_base_url=trading_base_url
        ),
        allow_live_trading=allow_live,
    )
    return AlpacaBroker(http, settings), http


def approved_buy(**brief_kwargs):
    brief = make_brief(**brief_kwargs)
    result = review(
        TradeDecision(decision="BUY", symbol="TEST", qty=10, reasoning="x", confidence="HIGH"),
        brief,
        AgentSettings().risk,
    )
    assert result.approved
    return result, brief


def test_dry_run_submits_nothing():
    result, brief = approved_buy()
    broker, http = make_broker()
    report = execute(result.decision, result.plan, brief, broker, dry_run=True)
    assert report.dry_run and not report.submitted
    assert http.posted == []


def test_execute_submits_a_bracket_order_with_the_stop_attached():
    result, brief = approved_buy()
    broker, http = make_broker()
    report = execute(result.decision, result.plan, brief, broker, dry_run=False)

    assert report.submitted and report.action == "opened"
    (path, body), = http.posted
    assert path == "/v2/orders"
    assert body["order_class"] == "bracket"
    assert body["side"] == "buy"
    assert body["symbol"] == "TEST"
    # The stop that justified the position size is actually on the order.
    assert float(body["stop_loss"]["stop_price"]) == pytest.approx(
        result.plan.stop_price, abs=0.01
    )
    assert float(body["take_profit"]["limit_price"]) == pytest.approx(
        result.plan.take_profit_price, abs=0.01
    )


def test_a_sell_against_an_open_long_reduces_rather_than_flipping_short():
    held = Position(symbol="TEST", qty=25, avg_entry_price=99.0, market_value=2_475.0)
    brief = make_brief(position=held)
    decision = TradeDecision(
        decision="SELL", symbol="TEST", qty=10, reasoning="x", confidence="HIGH"
    )
    broker, http = make_broker()
    report = execute(decision, None, brief, broker, dry_run=False)

    assert report.action == "reduced"
    (_, body), = http.posted
    assert body["side"] == "sell"
    assert body["reduce_only"] is True
    assert "order_class" not in body  # no bracket when taking risk off
    assert body["qty"] == "10"


def test_selling_more_than_is_held_closes_the_position_without_going_short():
    held = Position(symbol="TEST", qty=5, avg_entry_price=99.0, market_value=495.0)
    brief = make_brief(position=held)
    decision = TradeDecision(
        decision="SELL", symbol="TEST", qty=40, reasoning="x", confidence="HIGH"
    )
    broker, http = make_broker()
    report = execute(decision, None, brief, broker, dry_run=False)

    assert report.action == "closed"
    (_, body), = http.posted
    assert body["qty"] == "5"


def test_a_buy_against_an_open_short_covers_it():
    held = Position(symbol="TEST", qty=-12, avg_entry_price=99.0, market_value=-1_188.0)
    brief = make_brief(position=held)
    decision = TradeDecision(
        decision="BUY", symbol="TEST", qty=12, reasoning="x", confidence="HIGH"
    )
    broker, http = make_broker()
    report = execute(decision, None, brief, broker, dry_run=False)
    assert report.action == "closed"
    assert http.posted[0][1]["side"] == "buy"


def test_no_trade_submits_nothing():
    brief = make_brief()
    broker, http = make_broker()
    report = execute(no_trade("TEST", "nope"), None, brief, broker, dry_run=False)
    assert report.action == "skipped"
    assert http.posted == []


def test_opening_without_a_sizing_plan_is_refused():
    """An entry with no stop is exactly what the 2% rule forbids."""
    brief = make_brief()
    decision = TradeDecision(
        decision="BUY", symbol="TEST", qty=10, reasoning="x", confidence="HIGH"
    )
    broker, http = make_broker()
    report = execute(decision, None, brief, broker, dry_run=False)
    assert report.action == "failed"
    assert "unprotected" in report.error
    assert http.posted == []


def test_a_live_endpoint_is_blocked_unless_explicitly_enabled():
    result, brief = approved_buy()
    broker, http = make_broker(trading_base_url="https://api.alpaca.markets")
    with pytest.raises(LiveTradingBlocked, match="not a paper endpoint"):
        execute(result.decision, result.plan, brief, broker, dry_run=False)
    assert http.posted == []


def test_a_live_endpoint_works_once_explicitly_enabled():
    result, brief = approved_buy()
    broker, http = make_broker(
        trading_base_url="https://api.alpaca.markets", allow_live=True
    )
    report = execute(result.decision, result.plan, brief, broker, dry_run=False)
    assert report.submitted
    assert len(http.posted) == 1


def test_broker_errors_are_reported_not_swallowed():
    result, brief = approved_buy()
    broker, http = make_broker()

    def boom(path, json_body):
        raise RuntimeError("insufficient buying power")

    http.trading_post = boom
    report = execute(result.decision, result.plan, brief, broker, dry_run=False)
    assert report.action == "failed"
    assert "insufficient buying power" in report.error


def test_client_order_id_is_stable_within_a_minute_and_unique_across_symbols():
    brief_a = make_brief(symbol="AAA")
    brief_b = make_brief(symbol="BBB")
    d = TradeDecision(decision="BUY", symbol="AAA", qty=5, reasoning="x", confidence="HIGH")
    assert client_order_id(d, brief_a, 5) == client_order_id(d, brief_a, 5)
    assert client_order_id(d, brief_a, 5) != client_order_id(d, brief_b, 5)
    assert client_order_id(d, brief_a, 5) != client_order_id(d, brief_a, 6)


def test_a_live_endpoint_is_blocked_on_closing_orders_too():
    """The refusal must propagate from every write path, not just entries."""
    held = Position(symbol="TEST", qty=25, avg_entry_price=99.0, market_value=2_475.0)
    brief = make_brief(position=held)
    decision = TradeDecision(
        decision="SELL", symbol="TEST", qty=10, reasoning="x", confidence="HIGH"
    )
    broker, http = make_broker(trading_base_url="https://api.alpaca.markets")
    with pytest.raises(LiveTradingBlocked):
        execute(decision, None, brief, broker, dry_run=False)
    assert http.posted == []
