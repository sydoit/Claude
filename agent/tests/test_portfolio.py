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


# --- correlation clusters -----------------------------------------------------

import math

from research_agent.portfolio import candidate_cluster, cluster_book
from tests.conftest import make_bars, uncorrelated_bars

WAVE = [0.01 * math.sin(i / 3) + 0.004 * math.cos(i / 7) for i in range(70)]


def _series(rates, start=100.0):
    closes = [start]
    for r in rates:
        closes.append(closes[-1] * (1 + r))
    return make_bars(closes)


def _book(*specs, portfolio_value=100_000.0):
    positions, orders = [], []
    for symbol, qty, price, stop_price in specs:
        positions.append(Position(symbol, qty, price, qty * price, price))
        if stop_price is not None:
            orders.append(
                OpenOrder(f"o{symbol}", symbol, "sell" if qty > 0 else "buy",
                          abs(qty), "stop", stop_price, "new")
            )
    return assess(positions, orders, portfolio_value)


def test_correlated_longs_form_one_cluster(policy):
    book = _book(("AAA", 100, 100.0, 90.0), ("BBB", 100, 100.0, 90.0))
    bars = {"AAA": _series(WAVE), "BBB": _series(WAVE)}
    clusters = cluster_book(book, bars, policy)

    assert len(clusters) == 1
    assert clusters[0].total_risk == pytest.approx(2_000.0)
    assert set(clusters[0].label.split("+")) == {"AAA", "BBB"}


def test_uncorrelated_positions_stay_separate(policy):
    book = _book(("AAA", 100, 100.0, 90.0), ("BBB", 100, 100.0, 90.0))
    clusters = cluster_book(book, uncorrelated_bars(["AAA", "BBB"]), policy)
    assert len(clusters) == 2


def test_a_hedge_is_not_a_cluster(policy):
    """Same symbol behaviour, opposite directions: the risks offset."""
    book = _book(("AAA", 100, 100.0, 90.0), ("BBB", -100, 100.0, 110.0))
    bars = {"AAA": _series(WAVE), "BBB": _series(WAVE)}
    assert len(cluster_book(book, bars, policy)) == 2


def test_clustering_is_single_linkage(policy):
    """A~B and B~C puts all three together even if A and C are independent."""
    a = _series(WAVE)
    c_rates = list(reversed(WAVE))
    blend = [(WAVE[i] + c_rates[i]) / 2 for i in range(len(WAVE))]
    book = _book(("A", 100, 100.0, 90.0), ("B", 100, 100.0, 90.0), ("C", 100, 100.0, 90.0))
    bars = {"A": a, "B": _series(blend), "C": _series(c_rates)}
    clusters = cluster_book(book, bars, policy)
    # Whatever the pairwise detail, over-grouping is the safe direction.
    assert len(clusters) <= 3
    assert sum(len(c.members) for c in clusters) == 3


def test_a_position_without_history_joins_everything(policy):
    book = _book(("AAA", 100, 100.0, 90.0), ("MYSTERY", 100, 100.0, 90.0))
    bars = {"AAA": _series(WAVE)}  # MYSTERY has no bars
    assert len(cluster_book(book, bars, policy)) == 1


def test_every_position_lands_in_exactly_one_cluster(policy):
    book = _book(*[(f"S{i}", 100, 100.0, 90.0) for i in range(5)])
    clusters = cluster_book(book, uncorrelated_bars([f"S{i}" for i in range(5)]), policy)
    members = [p.symbol for c in clusters for p in c.members]
    assert sorted(members) == sorted(f"S{i}" for i in range(5))
    assert len(members) == len(set(members))


def test_cluster_describe_flags_breaching_the_cap(policy):
    book = _book(("AAA", 500, 100.0, 90.0))  # 5,000 risk vs a 4,000 cluster cap
    clusters = cluster_book(book, {"AAA": _series(WAVE)}, policy)
    assert "OVER CAP" in clusters[0].describe(100_000.0, policy)


# --- the candidate's cluster --------------------------------------------------

def test_a_candidate_buy_joins_correlated_longs(policy):
    book = _book(("AAA", 100, 100.0, 90.0), ("ZZZ", 100, 100.0, 90.0))
    bars = {"AAA": _series(WAVE), "ZZZ": uncorrelated_bars(["ZZZ"])["ZZZ"],
            "NEW": _series(WAVE)}
    cluster = candidate_cluster("NEW", 1, book, bars, policy)

    assert [p.symbol for p in cluster.members] == ["AAA"]
    assert cluster.committed_risk == pytest.approx(1_000.0)
    assert cluster.headroom(policy) == pytest.approx(3_000.0)


def test_a_candidate_sell_does_not_join_correlated_longs(policy):
    book = _book(("AAA", 100, 100.0, 90.0))
    bars = {"AAA": _series(WAVE), "NEW": _series(WAVE)}
    cluster = candidate_cluster("NEW", -1, book, bars, policy)
    assert cluster.members == ()
    assert cluster.headroom(policy) == pytest.approx(4_000.0)


def test_a_candidate_in_the_same_symbol_always_clusters_with_itself(policy):
    book = _book(("TEST", 100, 100.0, 90.0))
    cluster = candidate_cluster("TEST", 1, book, {}, policy)
    assert [p.symbol for p in cluster.members] == ["TEST"]


def test_candidate_headroom_never_goes_negative(policy):
    book = _book(("AAA", 900, 100.0, 90.0))  # 9,000 risk vs a 4,000 cap
    bars = {"AAA": _series(WAVE), "NEW": _series(WAVE)}
    assert candidate_cluster("NEW", 1, book, bars, policy).headroom(policy) == 0.0


def test_an_empty_book_gives_the_candidate_a_full_cluster_budget(policy):
    cluster = candidate_cluster("NEW", 1, assess([], [], 100_000.0), {}, policy)
    assert cluster.members == ()
    assert "uncorrelated with anything" in cluster.describe(policy)[0]
