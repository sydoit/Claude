import pytest

from research_agent.broker import OpenOrder, Position
from research_agent.config import ConfigError, RiskPolicy
from research_agent.portfolio import assess, measure_position, stop_for


def stop(symbol, side, price, order_type="stop"):
    return OpenOrder(
        id=f"o-{symbol}-{price}", symbol=symbol, side=side, qty=10,
        order_type=order_type, stop_price=price, status="new",
    )


def test_long_risk_is_distance_to_the_stop():
    pos = Position("AAA", 100, 50.0, 5_500.0, 55.0)
    risk = measure_position(pos, [stop("AAA", "sell", 52.0)])
    assert risk.risk_amount == pytest.approx(300.0)  # 100 x (55 - 52)
    assert risk.is_protected


def test_short_risk_is_distance_up_to_the_stop():
    pos = Position("BBB", -50, 20.0, -900.0, 18.0)
    risk = measure_position(pos, [stop("BBB", "buy", 21.0)])
    assert risk.risk_amount == pytest.approx(150.0)  # 50 x (21 - 18)


def test_an_unstopped_position_risks_its_whole_notional():
    pos = Position("CCC", 10, 300.0, 3_000.0, 300.0)
    risk = measure_position(pos, [])
    assert risk.stop_price is None
    assert not risk.is_protected
    assert risk.risk_amount == pytest.approx(3_000.0)
    assert "NO STOP" in risk.describe()


def test_a_stop_beyond_break_even_reports_zero_risk_not_negative():
    """A trailing stop above entry has locked in a profit, not a loss."""
    pos = Position("AAA", 100, 50.0, 5_500.0, 55.0)
    risk = measure_position(pos, [stop("AAA", "sell", 58.0)])
    assert risk.risk_amount == 0.0


def test_the_tightest_stop_is_the_one_that_binds():
    pos = Position("AAA", 100, 50.0, 5_500.0, 55.0)
    orders = [stop("AAA", "sell", 51.0), stop("AAA", "sell", 53.5)]
    assert stop_for("AAA", pos, orders) == 53.5  # highest stop wins on a long

    short = Position("BBB", -100, 50.0, -5_000.0, 50.0)
    orders = [stop("BBB", "buy", 55.0), stop("BBB", "buy", 52.0)]
    assert stop_for("BBB", short, orders) == 52.0  # lowest wins on a short


def test_a_same_side_order_is_not_mistaken_for_protection():
    """A buy-stop above a long is an add, not a stop-loss."""
    pos = Position("AAA", 100, 50.0, 5_500.0, 55.0)
    assert stop_for("AAA", pos, [stop("AAA", "buy", 60.0)]) is None


def test_orders_for_other_symbols_are_ignored():
    pos = Position("AAA", 100, 50.0, 5_500.0, 55.0)
    assert stop_for("AAA", pos, [stop("ZZZ", "sell", 54.0)]) is None


def test_non_stop_order_types_do_not_count_as_protection():
    pos = Position("AAA", 100, 50.0, 5_500.0, 55.0)
    limit = OpenOrder("x", "AAA", "sell", 10, "limit", None, "new")
    assert stop_for("AAA", pos, [limit]) is None


def test_trailing_stops_count_as_protection():
    pos = Position("AAA", 100, 50.0, 5_500.0, 55.0)
    trailing = stop("AAA", "sell", 53.0, order_type="trailing_stop")
    assert stop_for("AAA", pos, [trailing]) == 53.0


def test_exposure_totals_and_headroom(policy):
    positions = [
        Position("AAA", 100, 50.0, 5_500.0, 55.0),
        Position("BBB", -50, 20.0, -900.0, 18.0),
    ]
    orders = [stop("AAA", "sell", 52.0), stop("BBB", "buy", 21.0)]
    exposure = assess(positions, orders, 100_000.0)

    assert exposure.total_risk == pytest.approx(450.0)
    assert exposure.risk_pct() == pytest.approx(0.0045)
    assert exposure.budget(policy) == pytest.approx(6_000.0)
    assert exposure.headroom(policy) == pytest.approx(5_550.0)


def test_headroom_never_goes_negative(policy):
    pos = [Position("AAA", 1_000, 50.0, 55_000.0, 55.0)]
    exposure = assess(pos, [], 100_000.0)  # 55k at risk against a 6k cap
    assert exposure.headroom(policy) == 0.0


def test_headroom_can_exclude_a_symbol_being_replaced(policy):
    positions = [
        Position("AAA", 100, 50.0, 5_500.0, 55.0),
        Position("BBB", -50, 20.0, -900.0, 18.0),
    ]
    orders = [stop("AAA", "sell", 52.0), stop("BBB", "buy", 21.0)]
    exposure = assess(positions, orders, 100_000.0)
    assert exposure.headroom(policy, exclude_symbol="AAA") == pytest.approx(5_850.0)


def test_closed_positions_are_skipped():
    exposure = assess([Position("AAA", 0, 50.0, 0.0, 55.0)], [], 100_000.0)
    assert exposure.positions == ()
    assert exposure.total_risk == 0.0


def test_an_empty_book_has_the_full_budget(policy):
    exposure = assess([], [], 100_000.0)
    assert exposure.total_risk == 0.0
    assert exposure.headroom(policy) == pytest.approx(6_000.0)
    assert exposure.describe(policy) == ["  (no open positions)"]


def test_a_portfolio_cap_below_the_per_trade_cap_is_rejected():
    with pytest.raises(ConfigError, match="below max_risk_pct"):
        RiskPolicy(max_risk_pct=0.02, max_portfolio_risk_pct=0.01)


def test_position_price_falls_back_to_market_value():
    assert Position("AAA", 10, 50.0, 600.0).price == pytest.approx(60.0)
    assert Position("AAA", -10, 50.0, -600.0).price == pytest.approx(60.0)
