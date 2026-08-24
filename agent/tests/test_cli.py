"""End-to-end wiring, with the model call stubbed out."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from research_agent import cli, llm
from research_agent.llm import ModelOutcome
from research_agent.schema import TradeDecision, no_trade

FIXTURE = str(Path(__file__).parent / "fixtures" / "sample_bars.csv")


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
