import json
from datetime import datetime, timedelta, timezone

import pytest

from research_agent.score_cli import main, render
from research_agent.scoring import Summary, score_all
from tests.test_scoring import bar, plan

T0 = datetime(2026, 3, 2, 21, 0, tzinfo=timezone.utc)


def write_journal(tmp_path, records, day="2026-03-02"):
    path = tmp_path / f"journal-{day}.jsonl"
    path.write_text("\n".join(json.dumps(r) for r in records) + "\n")
    return path


def record(**overrides):
    base = {
        "ts": T0.isoformat(), "trading_day": "2026-03-02", "symbol": "TEST",
        "decision": "BUY", "qty": 10, "confidence": "HIGH", "entry": 100.0,
        "stop": 95.0, "target": 110.0, "stop_distance": 5.0, "executed": True,
        "reasoning": "Trend intact.",
    }
    base.update(overrides)
    return base


def bars_csv(tmp_path, rows):
    path = tmp_path / "bars.csv"
    lines = ["t,o,h,l,c,v"]
    for day, low, high, close in rows:
        ts = (T0 + timedelta(days=day)).isoformat().replace("+00:00", "Z")
        lines.append(f"{ts},{(low+high)/2},{high},{low},{close},1000")
    path.write_text("\n".join(lines) + "\n")
    return path


# --- rendering ------------------------------------------------------------------

def test_the_report_leads_with_expectancy():
    summary = score_all([plan()], {"TEST": [bar(1, 105, 111)]})
    text = render(summary, horizon=20, slippage_bps=0)
    assert "Outcome scoring" in text
    assert "Expectancy" in text and "+2.00R" in text
    assert "BY STATED CONFIDENCE" in text


def test_the_report_says_when_nothing_can_be_scored_yet():
    summary = score_all([plan()], {"TEST": []})
    text = render(summary, horizon=20, slippage_bps=0)
    assert "Nothing to score yet" in text
    assert "give it a few sessions" in text


def test_the_report_surfaces_the_same_bar_caveat():
    summary = score_all([plan()], {"TEST": [bar(1, 94, 111)]})
    text = render(summary, horizon=20, slippage_bps=0)
    assert "CAVEATS" in text and "stop was assumed" in text


def test_the_trade_list_is_capped():
    summary = Summary(
        score_all([plan() for _ in range(12)], {"TEST": [bar(1, 105, 111)]}).outcomes
    )
    assert "and 9 more" in render(summary, horizon=20, slippage_bps=0, show=3)


def test_a_by_symbol_section_appears_only_with_several_symbols():
    single = render(score_all([plan()], {"TEST": [bar(1, 105, 111)]}),
                    horizon=20, slippage_bps=0)
    assert "BY SYMBOL" not in single


# --- the cli --------------------------------------------------------------------

def test_scoring_a_journal_offline(tmp_path, capsys):
    write_journal(tmp_path, [record()])
    csv = bars_csv(tmp_path, [(1, 105, 111, 108)])
    assert main([str(tmp_path), "--offline", str(csv)]) == 0
    out = capsys.readouterr().out
    assert "hit target" in out and "+2.00R" in out


def test_a_stopped_trade_reports_a_loss(tmp_path, capsys):
    write_journal(tmp_path, [record()])
    csv = bars_csv(tmp_path, [(1, 94, 99, 96)])
    main([str(tmp_path), "--offline", str(csv)])
    out = capsys.readouterr().out
    assert "stopped out" in out and "-1.00R" in out


def test_json_output_is_machine_readable(tmp_path, capsys):
    write_journal(tmp_path, [record()])
    csv = bars_csv(tmp_path, [(1, 105, 111, 108)])
    assert main([str(tmp_path), "--offline", str(csv), "--json"]) == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["overall"]["count"] == 1
    assert payload["overall"]["expectancy_r"] == pytest.approx(2.0)
    assert payload["trades"][0]["result"] == "target"
    assert payload["by_confidence"]["HIGH"]["count"] == 1


def test_slippage_flag_reaches_the_numbers(tmp_path, capsys):
    write_journal(tmp_path, [record()])
    csv = bars_csv(tmp_path, [(1, 105, 111, 108)])
    main([str(tmp_path), "--offline", str(csv), "--slippage-bps", "50", "--json"])
    slipped = json.loads(capsys.readouterr().out)["overall"]["expectancy_r"]
    assert slipped < 2.0


def test_no_trade_records_are_skipped_without_complaint(tmp_path, capsys):
    write_journal(tmp_path, [record(decision="NO_TRADE", entry=None)])
    assert main([str(tmp_path)]) == 0
    assert "none of them trades to score" in capsys.readouterr().err


def test_a_missing_directory_is_an_error(tmp_path, capsys):
    assert main([str(tmp_path / "nope")]) == 1
    assert "no such log directory" in capsys.readouterr().err


def test_an_empty_log_directory_explains_the_journal(tmp_path, capsys):
    assert main([str(tmp_path)]) == 1
    assert "journal-*.jsonl" in capsys.readouterr().err


def test_unparseable_journal_lines_do_not_stop_scoring(tmp_path, capsys):
    path = tmp_path / "journal-2026-03-02.jsonl"
    path.write_text(json.dumps(record()) + "\nnot json at all\n")
    csv = bars_csv(tmp_path, [(1, 105, 111, 108)])
    assert main([str(tmp_path), "--offline", str(csv), "--json"]) == 0
    assert json.loads(capsys.readouterr().out)["overall"]["count"] == 1


def test_several_days_of_journals_are_combined(tmp_path, capsys):
    write_journal(tmp_path, [record()], day="2026-03-02")
    write_journal(tmp_path, [record(confidence="LOW")], day="2026-03-03")
    csv = bars_csv(tmp_path, [(1, 105, 111, 108)])
    main([str(tmp_path), "--offline", str(csv), "--json"])
    payload = json.loads(capsys.readouterr().out)
    assert payload["overall"]["count"] == 2
    assert set(payload["by_confidence"]) == {"HIGH", "LOW"}
