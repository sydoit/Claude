import json
from datetime import datetime, timezone

import pytest

from research_agent.broker import Account, OpenOrder, Position
from research_agent.config import MARKET_TZ, RiskPolicy
from research_agent.killswitch import evaluate
from research_agent.portfolio import assess, cluster_book
from research_agent.watch import BarCache, Paint, main, read_today, render
from tests.conftest import make_bars, uncorrelated_bars


@pytest.fixture
def paint():
    return Paint(False)


def acct(equity=100_000.0, last_equity=100_000.0):
    return Account(
        account_number="PA", portfolio_value=equity, buying_power=equity * 2,
        cash=equity, equity=equity, trading_blocked=False,
        pattern_day_trader=False, last_equity=last_equity,
    )


def book():
    positions = [
        Position("NVDA", 131, 185.0, 24_945.0, 190.42),
        Position("XYZ", 50, 60.0, 3_000.0, 60.0),
    ]
    orders = [OpenOrder("1", "NVDA", "sell", 131, "stop", 185.41, "new")]
    return assess(positions, orders, 100_000.0)


# --- the panel ----------------------------------------------------------------

def test_the_panel_reports_account_risk_and_positions(policy, paint):
    text = render(account=acct(), exposure=book(), drawdown=evaluate(acct(), policy),
                  decisions=[], policy=policy, paint=paint)
    assert "ACCOUNT" in text and "KILL SWITCH" in text
    assert "RISK" in text and "POSITIONS" in text
    assert "NVDA" in text


def test_an_unprotected_position_is_flagged(policy, paint):
    text = render(account=acct(), exposure=book(), decisions=[], policy=policy, paint=paint)
    assert "XYZ has no stop" in text


def test_a_tripped_kill_switch_is_prominent(policy, paint):
    down = acct(equity=95_000)
    text = render(account=down, exposure=book(), drawdown=evaluate(down, policy),
                  decisions=[], policy=policy, paint=paint)
    assert "TRIPPED" in text and "halted" in text


def test_an_untripped_kill_switch_shows_remaining_budget(policy, paint):
    text = render(account=acct(), exposure=book(), drawdown=evaluate(acct(), policy),
                  decisions=[], policy=policy, paint=paint)
    assert "daily budget left" in text


def test_a_flat_book_says_so(policy, paint):
    text = render(account=acct(), exposure=assess([], [], 100_000.0),
                  decisions=[], policy=policy, paint=paint)
    assert "flat" in text


def test_unmeasured_clusters_are_labelled_as_such(policy, paint):
    """The panel must not present a conservative default as a measurement."""
    exposure = book()
    text = render(account=acct(), exposure=exposure,
                  clusters=cluster_book(exposure, {}, policy), clusters_measured=False,
                  decisions=[], policy=policy, paint=paint)
    assert "CLUSTERS (unmeasured)" in text
    assert "grouped conservatively" in text


def test_measured_clusters_are_not_labelled_unmeasured(policy, paint):
    exposure = book()
    bars = uncorrelated_bars(["NVDA", "XYZ"])
    text = render(account=acct(), exposure=exposure,
                  clusters=cluster_book(exposure, bars, policy), clusters_measured=True,
                  decisions=[], policy=policy, paint=paint)
    assert "unmeasured" not in text


def test_an_error_is_surfaced_rather_than_a_blank_panel(policy, paint):
    text = render(policy=policy, paint=paint, decisions=[], error="broker unreachable: timeout")
    assert "broker unreachable" in text


def test_the_panel_states_it_never_trades(policy, paint):
    text = render(policy=policy, paint=paint, decisions=[])
    assert "never trades" in text


# --- decisions ------------------------------------------------------------------

def test_decisions_render_newest_first_with_times(policy, paint):
    rows = [
        {"ts": "2026-08-25T15:30:00+00:00", "decision": "NO_TRADE", "symbol": "NVDA",
         "qty": None, "confidence": "LOW", "vetoes": ["RSI 74.3 is overbought"]},
        {"ts": "2026-08-25T15:15:00+00:00", "decision": "BUY", "symbol": "NVDA",
         "qty": 131, "confidence": "HIGH", "reasoning": "Trend intact."},
    ]
    text = render(policy=policy, paint=paint, decisions=rows)
    assert "DECISIONS TODAY (2)" in text
    assert "RSI 74.3 is overbought" in text   # the veto, not the reasoning
    assert "BUY 131" in text


def test_a_decision_without_a_timestamp_still_renders(policy, paint):
    text = render(policy=policy, paint=paint,
                  decisions=[{"decision": "NO_TRADE", "symbol": "X", "confidence": "LOW"}])
    assert "NO_TRADE" in text


def test_no_decisions_yet_says_so(policy, paint):
    assert "(none yet)" in render(policy=policy, paint=paint, decisions=[])


def test_reading_today_prefers_the_journal(tmp_path):
    day = "2026-08-25"
    (tmp_path / f"decisions-{day}.jsonl").write_text('{"decision":"NO_TRADE"}\n')
    (tmp_path / f"journal-{day}.jsonl").write_text(
        '{"decision":"BUY","ts":"2026-08-25T15:00:00+00:00"}\n'
    )
    rows = read_today(tmp_path, day)
    assert rows[0]["decision"] == "BUY"   # journal has times, so it wins


def test_reading_today_falls_back_to_decisions(tmp_path):
    day = "2026-08-25"
    (tmp_path / f"decisions-{day}.jsonl").write_text('{"decision":"SELL"}\n')
    assert read_today(tmp_path, day)[0]["decision"] == "SELL"


def test_reading_today_is_newest_first(tmp_path):
    day = "2026-08-25"
    (tmp_path / f"journal-{day}.jsonl").write_text(
        '{"decision":"BUY","symbol":"FIRST"}\n{"decision":"SELL","symbol":"LAST"}\n'
    )
    assert read_today(tmp_path, day)[0]["symbol"] == "LAST"


def test_a_missing_log_directory_is_not_fatal(tmp_path):
    assert read_today(tmp_path / "nope", "2026-08-25") == []


def test_a_corrupt_log_line_is_skipped_not_fatal(tmp_path):
    """A half-written last line is normal while a run is in flight."""
    day = "2026-08-25"
    (tmp_path / f"journal-{day}.jsonl").write_text(
        '{"decision":"BUY","symbol":"FIRST"}\nbroken\n'
        '{"decision":"SELL","symbol":"LAST"}\n'
    )
    rows = read_today(tmp_path, day)
    assert [r["symbol"] for r in rows] == ["LAST", "FIRST"]  # still newest-first


# --- the bar cache ---------------------------------------------------------------

class CountingProvider:
    def __init__(self, bars=None, fail=()):
        self.calls = 0
        self._bars = bars or {}
        self._fail = set(fail)

    def bars(self, symbol, *, timeframe="1Day", limit=100, start=None, end=None):
        self.calls += 1
        if symbol in self._fail:
            raise ValueError("no data")
        return self._bars.get(symbol.upper(), make_bars([100.0] * 70))


def test_bars_are_fetched_once_and_reused():
    """Daily bars do not change intraday; refetching every 15s would be waste."""
    cache = BarCache(ttl_seconds=9999)
    provider = CountingProvider()
    cache.get(provider, ["NVDA", "AMD"], lookback=60)
    assert provider.calls == 2
    cache.get(provider, ["NVDA", "AMD"], lookback=60)
    assert provider.calls == 2   # served from cache


def test_a_new_symbol_triggers_a_fetch():
    cache = BarCache(ttl_seconds=9999)
    provider = CountingProvider()
    cache.get(provider, ["NVDA"], lookback=60)
    cache.get(provider, ["NVDA", "AMD"], lookback=60)
    assert provider.calls > 1


def test_a_symbol_with_no_data_is_left_out_not_faked():
    cache = BarCache(ttl_seconds=9999)
    bars = cache.get(CountingProvider(fail={"BAD"}), ["NVDA", "BAD"], lookback=60)
    assert "NVDA" in bars and "BAD" not in bars


def test_an_empty_cache_reports_itself_unmeasured():
    cache = BarCache()
    cache.get(CountingProvider(fail={"BAD"}), ["BAD"], lookback=60)
    assert not cache.measured


# --- the cli ----------------------------------------------------------------------

def test_logs_only_renders_without_a_broker(tmp_path, capsys):
    day = datetime.now(timezone.utc).astimezone(MARKET_TZ).date().isoformat()
    (tmp_path / f"journal-{day}.jsonl").write_text(
        json.dumps({"decision": "BUY", "symbol": "NVDA", "qty": 5,
                    "confidence": "HIGH", "reasoning": "x"}) + "\n"
    )
    assert main([str(tmp_path), "--once", "--logs-only", "--no-color",
                 "--env-file", "/nonexistent"]) == 0
    out = capsys.readouterr().out
    assert "logs-only" in out and "NVDA" in out


def test_once_renders_a_single_frame(tmp_path, capsys):
    assert main([str(tmp_path), "--once", "--logs-only", "--no-color",
                 "--env-file", "/nonexistent"]) == 0
    assert "Market Research Agent" in capsys.readouterr().out
