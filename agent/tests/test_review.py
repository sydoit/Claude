import json

import pytest

from research_agent.review import collect, main, normalise, render


@pytest.fixture
def logs(tmp_path):
    decisions = [
        {"decision": "BUY", "symbol": "NVDA", "qty": 131,
         "reasoning": "Trend intact.", "confidence": "HIGH"},
        {"decision": "NO_TRADE", "symbol": "NVDA", "qty": None,
         "reasoning": "Risk layer overrode the model to NO_TRADE: confidence LOW is "
                      "below the required MEDIUM. The model had proposed BUY 40 NVDA "
                      "at LOW confidence, reasoning: Looks fine.",
         "confidence": "LOW"},
        {"decision": "NO_TRADE", "symbol": "AAPL", "qty": None,
         "reasoning": "No edge here; price is mid-range.", "confidence": "MEDIUM"},
    ]
    (tmp_path / "decisions-2026-03-02.jsonl").write_text(
        "\n".join(json.dumps(d) for d in decisions) + "\n"
    )
    (tmp_path / "agent-2026-03-02.log").write_text("\n".join([
        "2026-03-02T10:00:00-05:00 === pass start [DRY RUN] symbols: NVDA AAPL ===",
        "[guardrail] VETO: confidence LOW is below the required MEDIUM",
        "[guardrail] adjusted: qty clamped from 5000.0 to 131 by the position concentration cap",
        "[execution] DRY RUN - would opened: BUY 131 NVDA",
    ]) + "\n")
    return tmp_path


# --- grouping -----------------------------------------------------------------

def test_numbers_are_flattened_so_like_reasons_group():
    assert normalise("RSI 74.3 is overbought") == normalise("RSI 71.8 is overbought")


def test_punctuation_survives_normalisation():
    assert normalise("trend is flat, so there is no edge") == (
        "trend is flat, so there is no edge"
    )


def test_thousands_separators_are_handled():
    assert normalise("day P&L -3,410.00 against") == "day P&L # against"


def test_a_trailing_period_is_dropped():
    assert normalise("no edge here.") == "no edge here"


# --- collection ---------------------------------------------------------------

def test_decisions_are_censused(logs):
    review = collect(logs)
    assert review.decisions == {"BUY": 1, "NO_TRADE": 2}
    assert review.total == 3
    assert review.days == ["2026-03-02"]


def test_wanted_trades_are_listed_with_their_reasoning(logs):
    trade, = collect(logs).trades
    assert trade["symbol"] == "NVDA" and trade["qty"] == 131
    assert trade["reasoning"] == "Trend intact."
    assert trade["day"] == "2026-03-02"


def test_overrides_are_counted_from_the_diary_not_double_counted(logs):
    review = collect(logs)
    assert review.vetoes == {"confidence LOW is below the required MEDIUM": 1}
    # The overridden decision must not also appear as a self-directed stand-down.
    assert all("Risk layer" not in reason for reason in review.stand_downs)


def test_self_directed_stand_downs_are_separated(logs):
    review = collect(logs)
    assert review.stand_downs == {"No edge here; price is mid-range": 1}


def test_adjustments_and_mode_are_read(logs):
    review = collect(logs)
    assert sum(review.adjustments.values()) == 1
    assert review.modes == {"DRY RUN": 1}
    assert review.passes == 1


def test_a_kill_switch_day_is_surfaced(tmp_path):
    (tmp_path / "agent-2026-03-04.log").write_text(
        "[kill-switch] HALTED: KILL SWITCH TRIPPED - day P&L -3,410.00\n"
    )
    assert "2026-03-04" in collect(tmp_path).kill_switch_days


def test_submitted_orders_are_listed(tmp_path):
    (tmp_path / "agent-2026-03-02.log").write_text(
        "[execution] SUBMITTED (opened): BUY 131 NVDA, stop 96.00\n"
    )
    assert len(collect(tmp_path).submitted) == 1


def test_an_unparseable_line_is_reported_not_fatal(tmp_path):
    (tmp_path / "decisions-2026-03-02.jsonl").write_text('{"decision":"BUY"}\nnot json\n')
    review = collect(tmp_path)
    assert review.decisions["BUY"] == 1
    assert any("unparseable" in e for e in review.errors)


def test_blank_lines_are_skipped(tmp_path):
    (tmp_path / "decisions-2026-03-02.jsonl").write_text(
        '{"decision":"NO_TRADE","reasoning":"x"}\n\n\n'
    )
    assert collect(tmp_path).total == 1


# --- rendering ----------------------------------------------------------------

def test_the_report_names_the_trades_and_the_vetoes(logs):
    text = render(collect(logs))
    assert "TRADES IT WANTED TO PLACE (1)" in text
    assert "NVDA" in text and "Trend intact." in text
    assert "confidence LOW is below the required MEDIUM" in text
    assert "dry run x1" in text


def test_an_empty_log_directory_says_so(tmp_path):
    assert "No logs found" in render(collect(tmp_path))


def test_a_run_with_no_trades_says_so(tmp_path):
    (tmp_path / "decisions-2026-03-02.jsonl").write_text(
        '{"decision":"NO_TRADE","symbol":"X","qty":null,"reasoning":"quiet","confidence":"LOW"}\n'
    )
    assert "stood down every time" in render(collect(tmp_path))


def test_the_trade_list_is_capped_and_says_how_many_were_hidden(tmp_path):
    rows = [
        {"decision": "BUY", "symbol": f"S{i}", "qty": 1, "reasoning": "x", "confidence": "HIGH"}
        for i in range(50)
    ]
    (tmp_path / "decisions-2026-03-02.jsonl").write_text(
        "\n".join(json.dumps(r) for r in rows) + "\n"
    )
    assert "and 45 more" in render(collect(tmp_path), show_trades=5)


# --- cli ----------------------------------------------------------------------

def test_the_cli_prints_a_report(logs, capsys):
    assert main([str(logs)]) == 0
    assert "Dry run review" in capsys.readouterr().out


def test_the_cli_can_emit_json(logs, capsys):
    assert main([str(logs), "--json"]) == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["decisions"] == {"BUY": 1, "NO_TRADE": 2}
    assert payload["days"] == ["2026-03-02"]


def test_a_missing_directory_is_an_error(tmp_path, capsys):
    assert main([str(tmp_path / "nope")]) == 1
    assert "no such log directory" in capsys.readouterr().err
