import pytest

from research_agent.broker import Account, OpenOrder, Position
from research_agent.config import RiskPolicy
from research_agent.killswitch import evaluate
from research_agent.portfolio import assess
from research_agent.screen import blocking_reason, interest_score, screen
from tests.conftest import et, flat_closes, make_brief, rising_closes


def acct(equity=100_000.0, last_equity=100_000.0):
    return Account(
        account_number="PA", portfolio_value=equity, buying_power=equity * 2,
        cash=equity, equity=equity, trading_blocked=False,
        pattern_day_trader=False, last_equity=last_equity,
    )


def full_book(portfolio_value=100_000.0):
    """A book whose risk budget is entirely spent."""
    positions = [Position(f"S{i}", 100, 100.0, 10_000.0, 100.0) for i in range(6)]
    orders = [OpenOrder(f"o{i}", f"S{i}", "sell", 100, "stop", 90.0, "new") for i in range(6)]
    return assess(positions, orders, portfolio_value)


# --- the deterministic filter -----------------------------------------------------

def test_a_normal_symbol_is_worth_asking_about(policy):
    assert blocking_reason(make_brief(), policy) is None


def test_a_closed_market_blocks_everything(policy):
    brief = make_brief(now=et(2026, 3, 2, 20, 0), market_open=False)
    assert "regular session" in blocking_reason(brief, policy)


def test_a_tripped_kill_switch_blocks_a_flat_symbol(policy):
    down = acct(equity=95_000)
    brief = make_brief(account=down)
    reason = blocking_reason(brief, policy, drawdown=evaluate(down, policy))
    assert "kill-switch tripped" in reason


def test_a_held_position_is_always_worth_asking_about(policy):
    """An exit is permitted even when every entry is blocked."""
    down = acct(equity=90_000)
    held = Position("TEST", 100, 100.0, 10_000.0, 100.0)
    brief = make_brief(account=down, position=held, exposure=full_book())
    assert blocking_reason(brief, policy, drawdown=evaluate(down, policy)) is None


def test_an_exhausted_book_blocks_a_flat_symbol(policy):
    brief = make_brief(exposure=full_book())
    reason = blocking_reason(brief, policy)
    assert reason is not None and "risk" in reason


def test_a_tiny_portfolio_blocks_on_sizing(policy):
    brief = make_brief(account=acct(equity=50.0, last_equity=50.0))
    assert "0 shares" in blocking_reason(brief, policy)


def test_the_filter_never_depends_on_the_models_answer(policy):
    """RSI direction and confidence are the guardrails' business, not the screen's."""
    overbought = make_brief(closes=rising_closes())
    assert blocking_reason(overbought, policy) is None


# --- ranking ------------------------------------------------------------------------

def test_a_bigger_move_scores_higher():
    quiet = make_brief(closes=flat_closes())
    mover = make_brief(closes=list(flat_closes())[:-1] + [140.0])
    assert interest_score(mover) > interest_score(quiet)


def test_the_score_is_bounded():
    wild = make_brief(closes=list(flat_closes())[:-1] + [10_000.0])
    assert interest_score(wild) <= 5.0 + 0.5 * 3.0


def test_the_score_is_never_negative():
    assert interest_score(make_brief(closes=flat_closes())) >= 0


# --- splitting the watchlist ----------------------------------------------------------

def test_candidates_come_back_highest_score_first(policy):
    briefs = {
        "QUIET": make_brief(closes=flat_closes(), symbol="QUIET"),
        "MOVER": make_brief(closes=list(flat_closes())[:-1] + [140.0], symbol="MOVER"),
    }
    candidates, skipped = screen(briefs, policy)
    assert [c.symbol for c in candidates] == ["MOVER", "QUIET"]
    assert skipped == []


def test_the_budget_caps_the_calls_and_the_rest_are_reported(policy):
    briefs = {f"S{i}": make_brief(symbol=f"S{i}") for i in range(6)}
    candidates, skipped = screen(briefs, policy, budget=2)
    assert len(candidates) == 2
    assert len(skipped) == 4
    assert all("budget of 2" in s.skip_reason for s in skipped)


def test_a_zero_budget_asks_nothing(policy):
    briefs = {"A": make_brief(symbol="A")}
    candidates, skipped = screen(briefs, policy, budget=0)
    assert candidates == [] and len(skipped) == 1


def test_no_budget_means_no_cap(policy):
    briefs = {f"S{i}": make_brief(symbol=f"S{i}") for i in range(6)}
    candidates, _ = screen(briefs, policy, budget=None)
    assert len(candidates) == 6


def test_blocked_symbols_never_consume_budget(policy):
    """The point of the filter: a full book spends nothing on flat symbols."""
    briefs = {f"S{i}": make_brief(symbol=f"S{i}", exposure=full_book()) for i in range(6)}
    candidates, skipped = screen(briefs, policy, budget=5)
    assert candidates == []
    assert len(skipped) == 6
    assert all("budget" not in s.skip_reason for s in skipped)


def test_a_held_symbol_keeps_its_place_when_the_book_is_full(policy):
    held = Position("HELD", 100, 100.0, 10_000.0, 100.0)
    briefs = {
        "HELD": make_brief(symbol="HELD", position=held, exposure=full_book()),
        "FLAT": make_brief(symbol="FLAT", exposure=full_book()),
    }
    candidates, skipped = screen(briefs, policy, budget=5)
    assert [c.symbol for c in candidates] == ["HELD"]
    assert [s.symbol for s in skipped] == ["FLAT"]


# --- the watchlist file ---------------------------------------------------------------

def test_a_watchlist_ignores_comments_and_blanks(tmp_path):
    from research_agent.scan import read_watchlist

    path = tmp_path / "w.txt"
    path.write_text("# header\n\nNVDA\n  AAPL  # inline note\n\n# trailing\n")
    assert read_watchlist(path) == ["NVDA", "AAPL"]


def test_a_watchlist_accepts_a_pasted_list(tmp_path):
    """Commas and spaces, so a list copied from anywhere needs no reformatting."""
    from research_agent.scan import read_watchlist

    path = tmp_path / "w.txt"
    path.write_text("nvda, aapl msft\nAMZN\n")
    assert read_watchlist(path) == ["NVDA", "AAPL", "MSFT", "AMZN"]


def test_a_watchlist_deduplicates_keeping_order(tmp_path):
    from research_agent.scan import read_watchlist

    path = tmp_path / "w.txt"
    path.write_text("NVDA\nAAPL\nnvda\n")
    assert read_watchlist(path) == ["NVDA", "AAPL"]


def test_scan_refuses_to_run_with_no_symbols(capsys):
    from research_agent.scan import main

    assert main(["--env-file", "/nonexistent"]) == 2
    assert "no symbols given" in capsys.readouterr().err


def test_scan_reports_an_unreadable_watchlist(capsys):
    from research_agent.scan import main

    assert main(["--watchlist", "/nonexistent.txt", "--env-file", "/nonexistent"]) == 2
    assert "cannot read watchlist" in capsys.readouterr().err
