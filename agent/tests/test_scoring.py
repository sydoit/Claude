from datetime import datetime, timedelta, timezone

import pytest

from research_agent.indicators import Bar
from research_agent.scoring import (
    OPEN,
    STOP,
    TARGET,
    UNSCORABLE,
    Summary,
    TradePlan,
    plan_from_record,
    score_all,
    score_trade,
)

T0 = datetime(2026, 3, 2, 21, 0, tzinfo=timezone.utc)


def bar(day, low, high, close=None):
    return Bar(
        ts=T0 + timedelta(days=day), open=(low + high) / 2, high=high, low=low,
        close=close if close is not None else (low + high) / 2, volume=1_000,
    )


def plan(decision="BUY", entry=100.0, stop=95.0, target=110.0, qty=10, confidence="HIGH"):
    return TradePlan(
        ts=T0, trading_day="2026-03-02", symbol="TEST", decision=decision, qty=qty,
        confidence=confidence, entry=entry, stop=stop, target=target,
        stop_distance=abs(entry - stop), executed=True,
    )


# --- the core replay ----------------------------------------------------------

def test_a_long_that_hits_its_target_scores_plus_two_r():
    """Target sits at 2x the stop distance, so a win is +2R by construction."""
    out = score_trade(plan(), [bar(1, 99, 101), bar(2, 105, 111)])
    assert out.result == TARGET
    assert out.r_multiple == pytest.approx(2.0)
    assert out.pnl == pytest.approx(100.0)   # 10 shares x 10.00
    assert out.bars_held == 2


def test_a_long_that_hits_its_stop_scores_minus_one_r():
    out = score_trade(plan(), [bar(1, 94, 99)])
    assert out.result == STOP
    assert out.r_multiple == pytest.approx(-1.0)
    assert out.pnl == pytest.approx(-50.0)


def test_a_short_that_hits_its_target_scores_plus_two_r():
    short = plan(decision="SELL", entry=100.0, stop=105.0, target=90.0)
    out = score_trade(short, [bar(1, 89, 95)])
    assert out.result == TARGET
    assert out.r_multiple == pytest.approx(2.0)


def test_a_short_that_hits_its_stop_scores_minus_one_r():
    short = plan(decision="SELL", entry=100.0, stop=105.0, target=90.0)
    out = score_trade(short, [bar(1, 99, 106)])
    assert out.result == STOP
    assert out.r_multiple == pytest.approx(-1.0)


def test_whichever_comes_first_wins_across_bars():
    """Stopped on day one, so a later touch of the target is irrelevant."""
    out = score_trade(plan(), [bar(1, 94, 99), bar(2, 105, 120)])
    assert out.result == STOP and out.bars_held == 1


# --- the pessimistic modelling choices ----------------------------------------

def test_stop_and_target_in_one_bar_assumes_the_stop():
    out = score_trade(plan(), [bar(1, 94, 111)])
    assert out.result == STOP
    assert "both inside one bar" in out.note


def test_scoring_starts_after_the_decision_not_on_its_own_bar():
    """A bar at or before the decision must not be scored against."""
    stale = Bar(ts=T0 - timedelta(days=1), open=100, high=120, low=90, close=100, volume=1)
    same = Bar(ts=T0, open=100, high=120, low=90, close=100, volume=1)
    out = score_trade(plan(), [stale, same])
    assert out.result == UNSCORABLE
    assert out.bars_held == 0


def test_an_unresolved_trade_is_marked_to_market_not_dropped():
    out = score_trade(plan(), [bar(1, 99, 101, close=103)], horizon=5)
    assert out.result == OPEN
    assert out.r_multiple == pytest.approx(3.0 / 5.0)
    assert "still open" in out.note


def test_the_horizon_bounds_how_long_a_trade_is_followed():
    bars = [bar(i, 99, 101, close=100) for i in range(1, 10)] + [bar(10, 105, 111)]
    assert score_trade(plan(), bars, horizon=5).result == OPEN
    assert score_trade(plan(), bars, horizon=20).result == TARGET


def test_a_trade_with_no_subsequent_bars_is_unscorable_not_a_loss():
    out = score_trade(plan(), [])
    assert out.result == UNSCORABLE and out.r_multiple == 0.0
    assert not out.scored


# --- slippage -----------------------------------------------------------------

def test_slippage_is_charged_against_the_trade_on_both_sides():
    clean = score_trade(plan(), [bar(1, 105, 111)])
    slipped = score_trade(plan(), [bar(1, 105, 111)], slippage_bps=10)
    assert slipped.r_multiple < clean.r_multiple
    assert slipped.pnl < clean.pnl


def test_slippage_hurts_a_short_too():
    short = plan(decision="SELL", entry=100.0, stop=105.0, target=90.0)
    clean = score_trade(short, [bar(1, 89, 95)])
    slipped = score_trade(short, [bar(1, 89, 95)], slippage_bps=25)
    assert slipped.r_multiple < clean.r_multiple


def test_slippage_makes_a_loss_worse():
    clean = score_trade(plan(), [bar(1, 94, 99)])
    slipped = score_trade(plan(), [bar(1, 94, 99)], slippage_bps=20)
    assert slipped.r_multiple < clean.r_multiple < 0


# --- parsing journal records ---------------------------------------------------

def _record(**overrides):
    base = {
        "ts": T0.isoformat(), "trading_day": "2026-03-02", "symbol": "test",
        "decision": "BUY", "qty": 10, "confidence": "HIGH", "entry": 100.0,
        "stop": 95.0, "target": 110.0, "stop_distance": 5.0, "executed": True,
    }
    base.update(overrides)
    return base


def test_a_complete_record_parses():
    parsed = plan_from_record(_record())
    assert parsed is not None
    assert parsed.symbol == "TEST"  # normalised
    assert parsed.is_long


def test_a_no_trade_record_is_skipped():
    assert plan_from_record(_record(decision="NO_TRADE")) is None


@pytest.mark.parametrize("missing", ["entry", "stop", "target", "stop_distance", "qty"])
def test_a_record_missing_its_plan_is_skipped(missing):
    assert plan_from_record(_record(**{missing: None})) is None


def test_a_zero_stop_distance_is_skipped():
    """Dividing R by zero would produce a meaningless number."""
    assert plan_from_record(_record(stop_distance=0)) is None


def test_a_malformed_record_is_skipped_not_fatal():
    assert plan_from_record(_record(entry="not a number")) is None
    assert plan_from_record(_record(ts="never")) is None


# --- aggregation ----------------------------------------------------------------

def _summary():
    wins = [bar(1, 105, 111)]
    losses = [bar(1, 94, 99)]
    return score_all(
        [
            plan(confidence="HIGH"),
            plan(confidence="HIGH"),
            plan(confidence="LOW"),
        ],
        {"TEST": wins},
    ), score_all([plan(confidence="LOW")], {"TEST": losses})


def test_expectancy_is_average_r_per_trade():
    winners = score_all([plan(), plan()], {"TEST": [bar(1, 105, 111)]})
    assert winners.expectancy == pytest.approx(2.0)
    assert winners.total_r == pytest.approx(4.0)
    assert winners.win_rate == 1.0


def test_a_mixed_book_averages_out():
    summary = Summary(
        score_all([plan()], {"TEST": [bar(1, 105, 111)]}).outcomes
        + score_all([plan()], {"TEST": [bar(1, 94, 99)]}).outcomes
    )
    assert summary.count == 2
    assert summary.total_r == pytest.approx(1.0)      # +2R and -1R
    assert summary.expectancy == pytest.approx(0.5)
    assert summary.win_rate == pytest.approx(0.5)
    assert summary.profit_factor == pytest.approx(2.0)


def test_profit_factor_is_none_without_trades():
    assert Summary([]).profit_factor is None
    assert Summary([]).expectancy == 0.0
    assert Summary([]).win_rate == 0.0


def test_profit_factor_is_infinite_with_no_losers():
    assert score_all([plan()], {"TEST": [bar(1, 105, 111)]}).profit_factor == float("inf")


def test_unscorable_trades_are_excluded_from_the_statistics():
    summary = score_all([plan(), plan()], {"TEST": []})
    assert summary.count == 0
    assert summary.outcomes and not summary.scored


def test_resolved_excludes_trades_still_open():
    summary = score_all([plan()], {"TEST": [bar(1, 99, 101, close=100)]}, horizon=3)
    assert summary.count == 1 and summary.resolved == []


def test_breakdown_by_confidence_separates_the_buckets():
    summary = Summary(
        score_all([plan(confidence="HIGH")], {"TEST": [bar(1, 105, 111)]}).outcomes
        + score_all([plan(confidence="LOW")], {"TEST": [bar(1, 94, 99)]}).outcomes
    )
    buckets = summary.by(lambda o: o.plan.confidence)
    assert buckets["HIGH"].expectancy == pytest.approx(2.0)
    assert buckets["LOW"].expectancy == pytest.approx(-1.0)


def test_a_symbol_with_no_bars_does_not_poison_the_others():
    summary = score_all(
        [plan(), TradePlan(ts=T0, trading_day="d", symbol="OTHER", decision="BUY",
                           qty=1, confidence="HIGH", entry=10, stop=9, target=12,
                           stop_distance=1, executed=True)],
        {"TEST": [bar(1, 105, 111)]},
    )
    assert summary.count == 1
    assert summary.expectancy == pytest.approx(2.0)
