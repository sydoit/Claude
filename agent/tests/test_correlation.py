import json
import math

import pytest

from research_agent.config import ConfigError, RiskPolicy
from research_agent.correlation import (
    aligned_returns,
    clusters_together,
    load_static_groups,
    measure,
    pearson,
    returns,
    sign,
)
from research_agent.indicators import Bar
from tests.conftest import BASE, make_bars, uncorrelated_bars

from datetime import timedelta


def series(rates, start=100.0):
    """Bars whose daily returns are exactly `rates`."""
    closes = [start]
    for r in rates:
        closes.append(closes[-1] * (1 + r))
    return make_bars(closes)


WAVE = [0.01 * math.sin(i / 3) + 0.004 * math.cos(i / 7) for i in range(70)]


# --- the maths ----------------------------------------------------------------

def test_pearson_endpoints():
    assert pearson([1, 2, 3, 4, 5], [2, 4, 6, 8, 10]) == pytest.approx(1.0)
    assert pearson([1, 2, 3, 4, 5], [10, 8, 6, 4, 2]) == pytest.approx(-1.0)


def test_pearson_is_undefined_for_a_flat_series():
    assert pearson([1, 1, 1, 1], [1, 2, 3, 4]) is None


def test_pearson_needs_two_observations():
    assert pearson([1], [2]) is None


def test_returns_are_fractional_changes():
    assert returns(make_bars([100.0, 110.0, 99.0])) == pytest.approx([0.1, -0.1])


def test_returns_survive_a_zero_price():
    assert returns(make_bars([0.0, 10.0])) == [0.0]


def test_sign_helper():
    assert (sign(5), sign(-5), sign(0)) == (1, -1, 0)


# --- alignment ----------------------------------------------------------------

def test_alignment_uses_only_shared_sessions():
    a = make_bars([100.0, 101.0, 102.0, 103.0])
    b = [
        Bar(BASE + timedelta(days=i), 50, 51, 49, c, 1000)
        for i, c in [(1, 50.0), (2, 51.0), (3, 52.0)]
    ]
    ra, rb = aligned_returns(a, b)
    assert len(ra) == len(rb) == 2  # three shared days -> two returns


def test_alignment_returns_nothing_when_no_days_overlap():
    a = make_bars([100.0, 101.0])
    b = [Bar(BASE + timedelta(days=90 + i), 5, 6, 4, 5.0, 10) for i in range(3)]
    assert aligned_returns(a, b) == ([], [])


# --- the signed-exposure rule -------------------------------------------------

def test_identical_symbols_always_correlate():
    r = measure("AAA", None, "AAA", None)
    assert r.value == 1.0 and r.basis == "same symbol"


def test_two_longs_in_lockstep_are_one_cluster(policy):
    bars = series(WAVE)
    r = measure("AAA", bars, "BBB", series(WAVE))
    assert r.value == pytest.approx(1.0, abs=1e-6)
    assert clusters_together(r, 100, 100, policy.correlation_threshold)


def test_a_long_and_a_short_in_lockstep_hedge_and_do_not_cluster(policy):
    r = measure("AAA", series(WAVE), "BBB", series(WAVE))
    assert not clusters_together(r, 100, -100, policy.correlation_threshold)
    assert r.effective(100, -100) == pytest.approx(-1.0, abs=1e-6)


def test_mirrored_symbols_held_oppositely_do_cluster(policy):
    """Short an inverse ETF against a long index: same bet, twice."""
    r = measure("AAA", series(WAVE), "INV", series([-x for x in WAVE]))
    assert r.value == pytest.approx(-1.0, abs=1e-2)
    assert clusters_together(r, 100, -100, policy.correlation_threshold)
    assert not clusters_together(r, 100, 100, policy.correlation_threshold)


def test_uncorrelated_symbols_do_not_cluster(policy):
    bars = uncorrelated_bars(["AAA", "BBB"])
    r = measure("AAA", bars["AAA"], "BBB", bars["BBB"])
    assert abs(r.value) < policy.correlation_threshold
    assert not clusters_together(r, 100, 100, policy.correlation_threshold)


# --- unmeasurable pairs are treated as correlated -----------------------------

def test_a_symbol_with_no_history_is_assumed_correlated(policy):
    r = measure("AAA", series(WAVE), "NEW", None)
    assert not r.measurable
    assert r.effective(1, 1) is None
    assert clusters_together(r, 100, 100, policy.correlation_threshold)
    assert clusters_together(r, 100, -100, policy.correlation_threshold)


def test_too_little_overlap_is_assumed_correlated(policy):
    r = measure("AAA", series(WAVE), "THIN", series(WAVE[:5]))
    assert not r.measurable
    assert "overlapping sessions" in r.basis
    assert clusters_together(r, 100, 100, policy.correlation_threshold)


def test_a_flat_series_is_assumed_correlated(policy):
    r = measure("AAA", series(WAVE), "FLAT", make_bars([100.0] * 70))
    assert not r.measurable
    assert r.basis == "flat return series"
    assert clusters_together(r, 100, 100, policy.correlation_threshold)


def test_the_lookback_bounds_the_observations():
    tight = measure("AAA", series(WAVE), "BBB", series(WAVE), lookback=30)
    assert tight.observations == 30


# --- static groups ------------------------------------------------------------

def test_a_static_group_forces_correlation_regardless_of_price(policy):
    bars = uncorrelated_bars(["AAA", "BBB"])
    groups = {"AAA": "semis", "BBB": "semis"}
    r = measure("AAA", bars["AAA"], "BBB", bars["BBB"], static_groups=groups)
    assert r.value == 1.0
    assert "static group" in r.basis
    assert clusters_together(r, 100, 100, policy.correlation_threshold)


def test_different_static_groups_fall_back_to_measurement(policy):
    bars = uncorrelated_bars(["AAA", "BBB"])
    groups = {"AAA": "semis", "BBB": "banks"}
    r = measure("AAA", bars["AAA"], "BBB", bars["BBB"], static_groups=groups)
    assert r.basis == "measured"
    assert not clusters_together(r, 100, 100, policy.correlation_threshold)


def test_static_groups_load_from_a_file(tmp_path):
    path = tmp_path / "groups.json"
    path.write_text(json.dumps({"semis": ["nvda", "AMD"], "banks": ["JPM"]}))
    mapping = load_static_groups(path)
    assert mapping == {"NVDA": "semis", "AMD": "semis", "JPM": "banks"}


def test_a_missing_groups_file_is_not_an_error():
    assert load_static_groups("/nonexistent/groups.json") == {}
    assert load_static_groups(None) == {}


def test_the_threshold_is_configurable():
    with pytest.raises(ConfigError):
        RiskPolicy(correlation_threshold=0)
    assert RiskPolicy(correlation_threshold=0.95).correlation_threshold == 0.95
