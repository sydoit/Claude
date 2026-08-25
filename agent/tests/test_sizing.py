import pytest

from research_agent.config import RiskPolicy
from research_agent.sizing import SizingError, plan_size


def test_risk_at_max_qty_never_exceeds_the_budget():
    policy = RiskPolicy()
    plan = plan_size(
        side="buy",
        entry_price=100.0,
        atr_value=2.0,
        portfolio_value=100_000,
        buying_power=1_000_000,
        policy=policy,
    )
    assert plan.risk_at_max_qty <= plan.risk_budget
    assert plan.risk_budget == pytest.approx(2_000.0)


@pytest.mark.parametrize("price", [1.5, 12.0, 97.3, 480.0, 3_100.0])
@pytest.mark.parametrize("atr_value", [0.05, 0.9, 4.4, 55.0])
@pytest.mark.parametrize("portfolio", [5_000.0, 100_000.0, 2_500_000.0])
def test_two_percent_rule_holds_across_a_sweep(price, atr_value, portfolio):
    """The 2% cap is the whole point. Sweep it rather than spot-check it."""
    policy = RiskPolicy()
    try:
        plan = plan_size(
            side="buy",
            entry_price=price,
            atr_value=atr_value,
            portfolio_value=portfolio,
            buying_power=portfolio * 4,
            policy=policy,
        )
    except SizingError:
        return  # refusing to size is always an acceptable outcome
    assert plan.risk_for(plan.max_qty) <= portfolio * 0.02 + 1e-9
    assert plan.max_qty * price <= portfolio * policy.max_position_pct + price


def test_buy_stop_sits_below_entry_and_sell_stop_above():
    policy = RiskPolicy()
    buy = plan_size(
        side="buy", entry_price=100.0, atr_value=2.0,
        portfolio_value=100_000, buying_power=100_000, policy=policy,
    )
    sell = plan_size(
        side="sell", entry_price=100.0, atr_value=2.0,
        portfolio_value=100_000, buying_power=100_000, policy=policy,
    )
    assert buy.stop_price < 100.0 < buy.take_profit_price
    assert sell.take_profit_price < 100.0 < sell.stop_price
    assert buy.stop_distance == pytest.approx(3.0)


def test_buying_power_can_be_the_binding_constraint():
    plan = plan_size(
        side="buy", entry_price=100.0, atr_value=0.5,
        portfolio_value=1_000_000, buying_power=1_000.0, policy=RiskPolicy(),
    )
    assert plan.max_qty == 10
    assert plan.binding_constraint == "buying power"


def test_zero_atr_is_refused_rather_than_guessed():
    with pytest.raises(SizingError, match="stop distance is undefined"):
        plan_size(
            side="buy", entry_price=100.0, atr_value=0.0,
            portfolio_value=100_000, buying_power=100_000, policy=RiskPolicy(),
        )


def test_atr_wider_than_price_is_refused():
    with pytest.raises(SizingError, match="too wide"):
        plan_size(
            side="buy", entry_price=10.0, atr_value=50.0,
            portfolio_value=100_000, buying_power=100_000, policy=RiskPolicy(),
        )


def test_invalid_inputs_are_rejected():
    policy = RiskPolicy()
    for kwargs in (
        dict(side="hold", entry_price=10.0, atr_value=1.0, portfolio_value=1000, buying_power=1000),
        dict(side="buy", entry_price=0.0, atr_value=1.0, portfolio_value=1000, buying_power=1000),
        dict(side="buy", entry_price=10.0, atr_value=1.0, portfolio_value=0, buying_power=1000),
    ):
        with pytest.raises(SizingError):
            plan_size(policy=policy, **kwargs)
