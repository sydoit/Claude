import pytest

from research_agent.broker import Position
from research_agent.config import RiskPolicy
from research_agent.guardrails import review
from research_agent.schema import TradeDecision, no_trade
from tests.conftest import (
    et,
    falling_closes,
    flat_closes,
    make_brief,
    rising_closes,
)


def buy(qty=10, confidence="HIGH", symbol="TEST", reasoning="Model rationale."):
    return TradeDecision(
        decision="BUY", symbol=symbol, qty=qty, reasoning=reasoning, confidence=confidence
    )


def sell(qty=10, confidence="HIGH", symbol="TEST", reasoning="Model rationale."):
    return TradeDecision(
        decision="SELL", symbol=symbol, qty=qty, reasoning=reasoning, confidence=confidence
    )


# --- the happy path -----------------------------------------------------------

def test_a_clean_trade_is_approved(policy):
    brief = make_brief()
    result = review(buy(qty=10), brief, policy)
    assert result.approved
    assert result.decision.decision == "BUY"
    assert result.plan is not None


# --- rule: regular market hours only -----------------------------------------

@pytest.mark.parametrize(
    "when,label",
    [
        (et(2026, 3, 2, 9, 0), "pre-market"),
        (et(2026, 3, 2, 16, 30), "after-hours"),
        (et(2026, 3, 2, 3, 0), "overnight"),
        (et(2026, 2, 28, 12, 0), "saturday"),
        (et(2026, 3, 1, 12, 0), "sunday"),
    ],
)
def test_trades_outside_regular_hours_are_vetoed(policy, when, label):
    brief = make_brief(now=when, market_open=None)
    result = review(buy(), brief, policy)
    assert not result.approved, label
    assert result.decision.decision == "NO_TRADE"
    assert any("regular session" in v for v in result.vetoes)


def test_session_boundaries_are_half_open(policy):
    """09:30 trades, 16:00 does not."""
    assert review(buy(), make_brief(now=et(2026, 3, 2, 9, 30)), policy).approved
    assert not review(buy(), make_brief(now=et(2026, 3, 2, 16, 0)), policy).approved


def test_broker_holiday_closure_outranks_the_clock(policy):
    """Inside 9:30-16:00 on a weekday, but the broker says the market is shut."""
    brief = make_brief(now=et(2026, 3, 2, 11, 0), market_open=False)
    result = review(buy(), brief, policy)
    assert not result.approved
    assert any("regular session" in v for v in result.vetoes)


# --- rule: no trading at RSI extremes ----------------------------------------

def test_buying_into_overbought_is_vetoed(policy):
    brief = make_brief(closes=rising_closes())  # RSI pinned at 100
    assert brief.rsi >= policy.rsi_overbought
    result = review(buy(), brief, policy)
    assert not result.approved
    assert any("overbought" in v for v in result.vetoes)


def test_selling_into_oversold_is_vetoed(policy):
    brief = make_brief(closes=falling_closes())  # RSI pinned at 0
    assert brief.rsi <= policy.rsi_oversold
    result = review(sell(), brief, policy)
    assert not result.approved
    assert any("oversold" in v for v in result.vetoes)


def test_high_confidence_contrarian_sell_into_overbought_is_allowed(policy):
    brief = make_brief(closes=rising_closes())
    result = review(sell(confidence="HIGH"), brief, policy)
    assert result.approved
    assert any("contrarian" in a for a in result.adjustments)


def test_contrarian_trade_needs_high_confidence(policy):
    brief = make_brief(closes=rising_closes())
    result = review(sell(confidence="MEDIUM"), brief, policy)
    assert not result.approved
    assert any("HIGH confidence" in v for v in result.vetoes)


def test_contrarian_override_can_be_disabled_by_policy():
    strict = RiskPolicy(allow_contrarian_override=False)
    brief = make_brief(closes=rising_closes(), policy=strict)
    result = review(sell(confidence="HIGH"), brief, strict)
    assert not result.approved
    assert any("disabled by policy" in v for v in result.vetoes)


def test_neutral_rsi_passes_the_extreme_check(policy):
    brief = make_brief(closes=flat_closes())
    assert policy.rsi_oversold < brief.rsi < policy.rsi_overbought
    assert review(buy(), brief, policy).approved


# --- rule: uncertainty defaults to NO_TRADE ----------------------------------

def test_low_confidence_is_vetoed_by_default(policy):
    result = review(buy(confidence="LOW"), make_brief(), policy)
    assert not result.approved
    assert any("below the required" in v for v in result.vetoes)


def test_confidence_floor_is_configurable():
    strict = RiskPolicy(min_confidence="HIGH")
    result = review(buy(confidence="MEDIUM"), make_brief(policy=strict), strict)
    assert not result.approved


def test_a_no_trade_decision_passes_through_untouched(policy):
    proposed = no_trade("TEST", "Nothing compelling here.", confidence="MEDIUM")
    result = review(proposed, make_brief(), policy)
    assert result.decision is proposed
    assert not result.vetoes
    assert not result.approved  # approved means "an order will be placed"


def test_stale_quotes_are_vetoed(policy):
    brief = make_brief(quote_age_seconds=600)
    result = review(buy(), brief, policy)
    assert not result.approved
    assert any("stale" in v for v in result.vetoes)


def test_a_blocked_account_is_vetoed(policy):
    result = review(buy(), make_brief(), policy, trading_blocked=True)
    assert not result.approved
    assert any("trading_blocked" in v for v in result.vetoes)


def test_symbol_substitution_is_vetoed(policy):
    """The model must trade what it was asked about, not what it fancies."""
    result = review(buy(symbol="OTHER"), make_brief(symbol="TEST"), policy,
                    requested_symbol="TEST")
    assert not result.approved
    assert any("symbol" in v for v in result.vetoes)


# --- rule: never risk more than 2% -------------------------------------------

def test_an_oversized_qty_is_clamped_not_rejected(policy):
    brief = make_brief()
    result = review(buy(qty=100_000), brief, policy)
    assert result.approved
    assert result.decision.qty < 100_000
    assert any("clamped" in a for a in result.adjustments)


def test_the_approved_qty_always_respects_the_two_percent_rule(policy):
    brief = make_brief()
    result = review(buy(qty=100_000), brief, policy)
    risk = result.plan.risk_for(result.decision.qty)
    assert risk <= brief.portfolio_value * policy.max_risk_pct


def test_a_tiny_portfolio_leaves_no_room_and_is_vetoed(policy):
    from research_agent.broker import Account

    pauper = Account(
        account_number="PA", portfolio_value=50.0, buying_power=50.0,
        cash=50.0, equity=50.0, trading_blocked=False, pattern_day_trader=False,
    )
    result = review(buy(qty=1), make_brief(account=pauper), policy)
    assert not result.approved
    assert any("0 shares" in v for v in result.vetoes)


def test_an_existing_position_consumes_the_concentration_budget(policy):
    held = Position(symbol="TEST", qty=200, avg_entry_price=100.0, market_value=20_000.0)
    brief = make_brief(position=held)
    result = review(buy(qty=100_000), brief, policy)
    if result.approved:
        assert result.decision.qty < 100_000
        assert any("consumes part of the cap" in a for a in result.adjustments)
    else:
        assert any("0 shares" in v for v in result.vetoes)


def test_fractional_qty_is_floored_to_whole_shares(policy):
    result = review(buy(qty=7.9), make_brief(), policy)
    assert result.approved
    assert result.decision.qty == 7.0


# --- the override is explained ------------------------------------------------

def test_an_override_explains_itself_and_keeps_the_model_rationale(policy):
    brief = make_brief(closes=rising_closes())
    result = review(buy(reasoning="Momentum looks great."), brief, policy)
    text = result.decision.reasoning
    assert "Risk layer overrode" in text
    assert "Momentum looks great." in text
    assert result.decision.confidence == "LOW"
    assert result.decision.qty is None


def test_multiple_broken_rules_are_all_reported(policy):
    brief = make_brief(now=et(2026, 3, 2, 20, 0), closes=rising_closes(), market_open=False)
    result = review(buy(confidence="LOW"), brief, policy)
    assert len(result.vetoes) >= 3
