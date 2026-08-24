"""End-to-end wiring, with the model call stubbed out."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from research_agent import cli, llm, research
from research_agent.llm import ModelOutcome
from research_agent.research import SessionState
from research_agent.schema import TradeDecision, no_trade
from tests.conftest import et

FIXTURE = str(Path(__file__).parent / "fixtures" / "sample_bars.csv")


def _session(open_now: bool) -> SessionState:
    return SessionState(
        now_et=et(2026, 3, 2, 11, 0),
        within_spec_window=open_now,
        broker_says_open=open_now,
        detail="forced open" if open_now else "forced closed",
    )


@pytest.fixture(autouse=True)
def market_open(monkeypatch):
    """Pin the session clock.

    Without this the CLI reads the wall clock, so the whole file would pass on
    a Tuesday afternoon and fail on a Saturday.
    """
    monkeypatch.setattr(research, "evaluate_session", lambda *a, **k: _session(True))


@pytest.fixture
def market_closed(monkeypatch):
    monkeypatch.setattr(research, "evaluate_session", lambda *a, **k: _session(False))


def stub_model(decision: TradeDecision):
    def _propose(brief, settings, client=None):
        return ModelOutcome(decision=decision)

    return _propose


def run(monkeypatch, capsys, decision, argv=None):
    monkeypatch.setattr(cli, "propose_decision", stub_model(decision))
    monkeypatch.setattr(llm, "propose_decision", stub_model(decision))
    code = cli.main(
        argv or ["TEST", "--offline", FIXTURE, "--portfolio-value", "100000", "--env-file", "/nonexistent"]
    )
    out = capsys.readouterr()
    return code, out


def test_stdout_carries_only_the_decision_json(monkeypatch, capsys):
    code, out = run(
        monkeypatch, capsys,
        TradeDecision(decision="BUY", symbol="TEST", qty=20, reasoning="Trend is intact.", confidence="HIGH"),
    )
    assert code == 0
    payload = json.loads(out.out)  # the entire stdout must parse as one object
    assert list(payload) == ["decision", "symbol", "qty", "reasoning", "confidence"]
    assert out.err  # diagnostics went to stderr instead


def test_offline_mode_never_submits_an_order(monkeypatch, capsys):
    code, out = run(
        monkeypatch, capsys,
        TradeDecision(decision="BUY", symbol="TEST", qty=20, reasoning="x", confidence="HIGH"),
    )
    assert code == 0
    assert "offline mode: nothing submitted" in out.err


def test_a_vetoed_decision_still_emits_valid_json(monkeypatch, capsys):
    code, out = run(
        monkeypatch, capsys,
        TradeDecision(decision="BUY", symbol="TEST", qty=20, reasoning="Gut feel.", confidence="LOW"),
    )
    payload = json.loads(out.out)
    assert payload["decision"] == "NO_TRADE"
    assert payload["qty"] is None
    assert "Risk layer overrode" in payload["reasoning"]
    assert "[guardrail] VETO" in out.err


def test_a_model_no_trade_passes_straight_through(monkeypatch, capsys):
    code, out = run(monkeypatch, capsys, no_trade("TEST", "Nothing on offer.", "MEDIUM"))
    payload = json.loads(out.out)
    assert payload["decision"] == "NO_TRADE"
    assert payload["reasoning"] == "Nothing on offer."


def test_an_unknown_fixture_yields_a_no_trade_not_a_crash(monkeypatch, capsys):
    monkeypatch.setattr(cli, "propose_decision", stub_model(no_trade("TEST", "x")))
    code = cli.main(
        ["TEST", "--offline", "/nonexistent.csv", "--portfolio-value", "100000", "--env-file", "/nonexistent"]
    )
    assert code == 1
    out = capsys.readouterr()
    assert json.loads(out.out)["decision"] == "NO_TRADE"


def test_offline_without_a_portfolio_value_is_refused(monkeypatch, capsys):
    monkeypatch.setattr(cli, "propose_decision", stub_model(no_trade("TEST", "x")))
    code = cli.main(["TEST", "--offline", FIXTURE, "--env-file", "/nonexistent"])
    assert code == 1
    assert "--portfolio-value" in capsys.readouterr().err


def test_reset_kill_switch_clears_the_latch(tmp_path, capsys):
    latch = tmp_path / "k.json"
    latch.write_text('{"trading_day": "2026-03-02"}')
    code = cli.main(["TEST", "--reset-kill-switch", "--kill-switch-file", str(latch),
                     "--env-file", "/nonexistent"])
    assert code == 0
    assert not latch.exists()
    assert "re-armed" in capsys.readouterr().err


def test_reset_is_harmless_when_nothing_is_latched(tmp_path, capsys):
    code = cli.main(["TEST", "--reset-kill-switch",
                     "--kill-switch-file", str(tmp_path / "absent.json"),
                     "--env-file", "/nonexistent"])
    assert code == 0


def test_offline_runs_are_not_halted_by_a_missing_baseline(monkeypatch, capsys):
    """An offline day has no P&L history and must read as flat, not unmeasurable."""
    code, out = run(
        monkeypatch, capsys,
        TradeDecision(decision="BUY", symbol="TEST", qty=20, reasoning="x", confidence="HIGH"),
    )
    assert code == 0
    assert "kill-switch] ok" in out.err
    assert json.loads(out.out)["decision"] == "BUY"


def test_a_closed_market_skips_the_model_call(monkeypatch, capsys, market_closed):
    """A schedule that fires on a holiday must not pay for a decision."""
    called = []

    def _never(brief, settings, client=None):
        called.append(brief.symbol)
        return ModelOutcome(decision=no_trade("TEST", "should not happen"))

    monkeypatch.setattr(cli, "propose_decision", _never)
    code = cli.main(
        ["TEST", "--offline", FIXTURE, "--portfolio-value", "100000",
         "--env-file", "/nonexistent"]
    )
    out = capsys.readouterr()

    assert code == 0
    assert called == []  # the expensive part never ran
    payload = json.loads(out.out)
    assert payload["decision"] == "NO_TRADE"
    assert "not in its regular session" in payload["reasoning"]
    assert "skipped: market closed" in out.err


def test_compact_output_is_one_line(monkeypatch, capsys):
    code, out = run(
        monkeypatch, capsys,
        TradeDecision(decision="BUY", symbol="TEST", qty=20, reasoning="x", confidence="HIGH"),
        argv=["TEST", "--offline", FIXTURE, "--portfolio-value", "100000",
              "--env-file", "/nonexistent", "--compact"],
    )
    assert code == 0
    assert out.out.strip().count("\n") == 0
    assert json.loads(out.out)["decision"] == "BUY"


def test_compact_applies_to_failure_output(monkeypatch, capsys):
    monkeypatch.setattr(cli, "propose_decision", stub_model(no_trade("TEST", "x")))
    code = cli.main(
        ["TEST", "--offline", "/nonexistent.csv", "--portfolio-value", "100000",
         "--env-file", "/nonexistent", "--compact"]
    )
    out = capsys.readouterr()
    assert code == 1
    assert out.out.strip().count("\n") == 0
    assert json.loads(out.out)["decision"] == "NO_TRADE"
