import math

import pytest

from research_agent.indicators import InsufficientData, atr, ema, pct_change, rsi, sma
from tests.conftest import falling_closes, make_bars, rising_closes


def test_rsi_hand_computed_case():
    """closes [10,11,10,12], period 2 -> avg gain 1.25, avg loss 0.25, RS 5."""
    bars = make_bars([10, 11, 10, 12])
    assert rsi(bars, period=2) == pytest.approx(100 - 100 / 6, rel=1e-9)


def test_rsi_saturates_on_a_pure_uptrend():
    assert rsi(make_bars(rising_closes()), 14) == pytest.approx(100.0)


def test_rsi_bottoms_on_a_pure_downtrend():
    assert rsi(make_bars(falling_closes()), 14) == pytest.approx(0.0)


def test_rsi_is_fifty_when_nothing_moves():
    assert rsi(make_bars([100.0] * 40), 14) == pytest.approx(50.0)


@pytest.mark.parametrize("closes", [rising_closes(40), falling_closes(40), [100.0] * 40])
def test_rsi_stays_in_range(closes):
    assert 0.0 <= rsi(make_bars(closes), 14) <= 100.0


def test_rsi_needs_period_plus_one_bars():
    with pytest.raises(InsufficientData):
        rsi(make_bars([1, 2, 3]), 14)


def test_atr_of_a_constant_band_equals_the_band():
    # Every bar spans exactly 2.0 and never gaps, so every true range is 2.0.
    assert atr(make_bars([100.0] * 40, spread=2.0), 14) == pytest.approx(2.0)


def test_atr_includes_gaps_between_bars():
    # A steady +1/bar drift with a 1.0 band makes TR = high - prev_close = 1.5.
    value = atr(make_bars(rising_closes(40, step=1.0), spread=1.0), 14)
    assert value == pytest.approx(1.5)


def test_atr_is_positive_and_finite():
    value = atr(make_bars(rising_closes(40)), 14)
    assert value > 0 and math.isfinite(value)


def test_sma_and_ema_track_a_flat_series():
    bars = make_bars([100.0] * 40)
    assert sma(bars, 20) == pytest.approx(100.0)
    assert ema(bars, 20) == pytest.approx(100.0)


def test_pct_change_matches_the_arithmetic():
    bars = make_bars([100.0, 110.0])
    assert pct_change(bars, 1) == pytest.approx(10.0)


def test_indicators_refuse_short_histories():
    for fn in (sma, ema):
        with pytest.raises(InsufficientData):
            fn(make_bars([1, 2, 3]), 20)
