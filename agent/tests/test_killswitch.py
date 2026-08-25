import json
from datetime import datetime, timedelta, timezone

import pytest

from research_agent.broker import Account
from research_agent.config import ConfigError, RiskPolicy
from research_agent.killswitch import (
    FileLatchStore,
    NullLatchStore,
    evaluate,
    trading_day,
)
from tests.conftest import et


def acct(equity, last_equity=100_000.0):
    return Account(
        account_number="PA", portfolio_value=equity, buying_power=equity * 2,
        cash=equity, equity=equity, trading_blocked=False,
        pattern_day_trader=False, last_equity=last_equity,
    )


# --- the measurement ----------------------------------------------------------

@pytest.mark.parametrize(
    "equity,tripped",
    [
        (105_000, False),   # up on the day
        (100_000, False),   # flat
        (98_000, False),    # -2%, inside the limit
        (97_000, True),     # -3%, exactly at the limit
        (90_000, True),     # -10%
    ],
)
def test_the_limit_is_inclusive(policy, equity, tripped):
    assert evaluate(acct(equity), policy).tripped is tripped


def test_the_baseline_is_the_prior_close_not_the_starting_capital(policy):
    """Yesterday's gains raise the bar; the day is measured from the close."""
    state = evaluate(acct(99_000, last_equity=102_000), policy)
    assert state.pnl == pytest.approx(-3_000.0)
    assert state.pnl_pct == pytest.approx(-3_000 / 102_000)
    assert not state.tripped  # -2.94%, inside a 3% limit


def test_the_limit_is_configurable():
    tight = RiskPolicy(max_daily_drawdown_pct=0.02)
    assert evaluate(acct(97_500), tight).tripped     # -2.5%
    assert not evaluate(acct(97_500), RiskPolicy()).tripped


def test_a_missing_baseline_halts_rather_than_guesses(policy):
    """No prior close means no measurable floor under the day."""
    state = evaluate(acct(100_000, last_equity=0.0), policy)
    assert state.tripped and not state.measurable
    assert "cannot be measured" in state.detail


def test_describe_reports_remaining_budget(policy):
    assert "1,000.00 of daily loss budget left" in evaluate(acct(98_000), policy).describe()
    assert "KILL SWITCH TRIPPED" in evaluate(acct(95_000), policy).describe()


def test_trading_day_uses_eastern_time():
    # 01:00 UTC is still the previous afternoon in New York.
    assert trading_day(datetime(2026, 3, 3, 1, 0, tzinfo=timezone.utc)).isoformat() == "2026-03-02"


# --- the latch ----------------------------------------------------------------

def test_the_switch_latches_for_the_rest_of_the_day(policy, tmp_path):
    store = FileLatchStore(tmp_path / "k.json")
    now = et(2026, 3, 2, 11, 0)

    assert evaluate(acct(95_000), policy, now=now, store=store).tripped
    # Equity recovers to a level that would not trip on its own...
    recovered = evaluate(acct(100_000), policy, now=now + timedelta(hours=1), store=store)
    assert recovered.tripped and recovered.latched  # ...but the day is over


def test_the_latch_clears_on_the_next_trading_day(policy, tmp_path):
    store = FileLatchStore(tmp_path / "k.json")
    evaluate(acct(95_000), policy, now=et(2026, 3, 2, 11, 0), store=store)
    tomorrow = evaluate(acct(100_000), policy, now=et(2026, 3, 3, 11, 0), store=store)
    assert not tomorrow.tripped and not tomorrow.latched


def test_the_latch_records_why_it_tripped(policy, tmp_path):
    path = tmp_path / "k.json"
    evaluate(acct(95_000), policy, now=et(2026, 3, 2, 11, 0), store=FileLatchStore(path))
    record = json.loads(path.read_text())
    assert record["trading_day"] == "2026-03-02"
    assert record["pnl"] == pytest.approx(-5_000.0)
    assert record["limit_pct"] == pytest.approx(0.03)


def test_a_profitable_day_writes_no_latch(policy, tmp_path):
    path = tmp_path / "k.json"
    evaluate(acct(105_000), policy, now=et(2026, 3, 2, 11, 0), store=FileLatchStore(path))
    assert not path.exists()


def test_clearing_the_latch_re_arms_the_day(policy, tmp_path):
    store = FileLatchStore(tmp_path / "k.json")
    now = et(2026, 3, 2, 11, 0)
    evaluate(acct(95_000), policy, now=now, store=store)
    store.clear()
    assert not evaluate(acct(100_000), policy, now=now, store=store).tripped


def test_latching_can_be_disabled(tmp_path):
    policy = RiskPolicy(kill_switch_latch=False)
    store = FileLatchStore(tmp_path / "k.json")
    now = et(2026, 3, 2, 11, 0)
    assert evaluate(acct(95_000), policy, now=now, store=store).tripped
    # Without latching the switch follows live equity back up.
    assert not evaluate(acct(100_000), policy, now=now, store=store).tripped


def test_a_corrupt_latch_file_is_ignored(policy, tmp_path):
    path = tmp_path / "k.json"
    path.write_text("{ not json")
    assert not evaluate(acct(100_000), policy, store=FileLatchStore(path)).tripped


def test_an_unwritable_latch_still_halts_this_run(policy, tmp_path):
    """Failing to persist must not silently disarm the switch."""
    store = FileLatchStore(tmp_path / "no-such-dir" / "k.json")
    assert evaluate(acct(95_000), policy, store=store).tripped


def test_the_null_store_evaluates_fresh_each_run(policy):
    now = et(2026, 3, 2, 11, 0)
    store = NullLatchStore()
    assert evaluate(acct(95_000), policy, now=now, store=store).tripped
    assert not evaluate(acct(100_000), policy, now=now, store=store).tripped


# --- configuration ------------------------------------------------------------

def test_a_drawdown_limit_below_the_per_trade_cap_is_rejected():
    with pytest.raises(ConfigError, match="below max_risk_pct"):
        RiskPolicy(max_risk_pct=0.02, max_daily_drawdown_pct=0.01)


def test_a_nonsensical_drawdown_limit_is_rejected():
    for value in (0, -0.1, 1.5):
        with pytest.raises(ConfigError):
            RiskPolicy(max_daily_drawdown_pct=value)
