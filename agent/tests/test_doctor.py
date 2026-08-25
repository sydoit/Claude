import json
from pathlib import Path

import pytest

from research_agent.doctor import (
    FAIL,
    OK,
    SKIP,
    WARN,
    Report,
    check_env_file,
    check_logs,
    check_packages,
    check_python,
    check_timezone,
    main,
)


@pytest.fixture
def report():
    return Report()


@pytest.fixture(autouse=True)
def no_ambient_keys(monkeypatch):
    for var in ("ANTHROPIC_API_KEY", "APCA_API_KEY_ID", "APCA_API_SECRET_KEY"):
        monkeypatch.delenv(var, raising=False)


def statuses(report):
    return {name: status for status, name, *_ in report.rows}


# --- the report -----------------------------------------------------------------

def test_counts_failures_and_warnings(report):
    report.add(OK, "a")
    report.add(WARN, "b")
    report.add(FAIL, "c")
    report.add(FAIL, "d")
    assert report.failed == 2 and report.warned == 1


def test_a_clean_report_says_so(report):
    report.add(OK, "everything")
    assert "Everything checks out" in report.render()


def test_warnings_alone_do_not_block(report):
    report.add(WARN, "a", "detail")
    text = report.render()
    assert "Ready to run" in text and "1 warning" in text


def test_failures_lead_the_summary(report):
    report.add(FAIL, "a", "broken")
    assert "1 blocking problem" in report.render()


def test_a_fix_is_shown_for_problems_but_not_for_passes(report):
    report.add(FAIL, "a", "broken", "do this")
    report.add(OK, "b", "fine", "irrelevant advice")
    text = report.render()
    assert "do this" in text
    assert "irrelevant advice" not in text


# --- individual checks ------------------------------------------------------------

def test_python_version_passes_here(report):
    check_python(report)
    assert statuses(report)["python"] == OK


def test_installed_dependencies_pass(report):
    check_packages(report)
    assert statuses(report)["dependencies"] == OK


def test_the_timezone_check_reads_the_market_clock(report):
    check_timezone(report)
    assert statuses(report)["timezone"] == OK
    assert "ET" in report.rows[0][2] or "EDT" in report.rows[0][2] or "EST" in report.rows[0][2]


def test_missing_keys_are_reported_as_blocking(report, tmp_path):
    check_env_file(report, tmp_path / ".env")
    seen = statuses(report)
    assert seen["ANTHROPIC_API_KEY"] == FAIL
    assert seen["APCA_API_KEY_ID"] == FAIL
    assert seen[".env"] == WARN


def test_present_keys_pass_without_revealing_them(report, tmp_path, monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-secretvalue123")
    monkeypatch.setenv("APCA_API_KEY_ID", "PKREALKEYID")
    monkeypatch.setenv("APCA_API_SECRET_KEY", "supersecret")
    env = tmp_path / ".env"
    env.write_text("x=1\n")
    check_env_file(report, env)

    text = report.render()
    assert statuses(report)["ANTHROPIC_API_KEY"] == OK
    assert "secretvalue123" not in text     # never echo a credential
    assert "PKREALKEYID" not in text


def test_a_placeholder_key_is_caught(report, tmp_path, monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-...")
    monkeypatch.setenv("APCA_API_KEY_ID", "PK1")
    monkeypatch.setenv("APCA_API_SECRET_KEY", "s")
    check_env_file(report, tmp_path / ".env")
    assert statuses(report)["ANTHROPIC_API_KEY"] == FAIL
    assert "placeholder" in report.render()


# --- logs -------------------------------------------------------------------------

def test_a_missing_log_directory_explains_when_it_appears(report, tmp_path):
    check_logs(report, tmp_path / "logs")
    assert statuses(report)["logs"] == WARN
    assert "first scheduled run" in report.render()


def test_an_empty_log_directory_points_at_the_scheduler(report, tmp_path):
    (tmp_path / "logs").mkdir()
    check_logs(report, tmp_path / "logs")
    assert statuses(report)["logs"] == WARN
    assert "not completed a pass" in report.render()


def test_populated_logs_are_counted(report, tmp_path):
    logs = tmp_path / "logs"
    logs.mkdir()
    (logs / "decisions-2026-08-25.jsonl").write_text(
        '{"decision":"BUY"}\n{"decision":"NO_TRADE"}\n'
    )
    (logs / "agent-2026-08-25.log").write_text("=== pass start [DRY RUN] ===\n")
    check_logs(report, logs)
    assert statuses(report)["logs"] == OK
    assert "2 decision(s)" in report.render()


def test_logs_without_journals_say_they_cannot_be_scored(report, tmp_path):
    logs = tmp_path / "logs"
    logs.mkdir()
    (logs / "decisions-2026-08-25.jsonl").write_text('{"decision":"BUY"}\n')
    check_logs(report, logs)
    assert "cannot be scored" in report.render()


def test_journals_are_reported_as_scoreable(report, tmp_path):
    logs = tmp_path / "logs"
    logs.mkdir()
    (logs / "decisions-2026-08-25.jsonl").write_text('{"decision":"BUY"}\n')
    (logs / "journal-2026-08-25.jsonl").write_text(json.dumps({"decision": "BUY"}) + "\n")
    check_logs(report, logs)
    assert "scoreable" in report.render()


def test_a_failing_last_run_is_surfaced(report, tmp_path):
    """The exact case that produced 'file does not exist'."""
    logs = tmp_path / "logs"
    logs.mkdir()
    (logs / "decisions-2026-08-25.jsonl").write_text('{"decision":"BUY"}\n')
    (logs / "agent-2026-08-25.log").write_text(
        "2026-08-25T14:00:00Z no .env and no ANTHROPIC_API_KEY in the environment\n"
    )
    check_logs(report, logs)
    assert statuses(report)["last run"] == WARN


# --- the cli ------------------------------------------------------------------------

def test_the_cli_exits_nonzero_when_something_blocks(tmp_path, capsys):
    code = main(["--env-file", str(tmp_path / "nope.env"), "--log-dir", str(tmp_path)])
    out = capsys.readouterr().out
    assert code == 1
    assert "blocking problem" in out
    assert "ANTHROPIC_API_KEY" in out


def test_the_cli_skips_the_model_probe_by_default(tmp_path, capsys):
    main(["--env-file", str(tmp_path / "nope.env"), "--log-dir", str(tmp_path)])
    assert "pass --probe" in capsys.readouterr().out


def test_the_report_never_crashes_on_a_broken_environment(tmp_path, capsys):
    """A doctor that dies on a sick patient is no use."""
    code = main(["--env-file", "/nonexistent", "--log-dir", "/nonexistent",
                 "--symbol", "ZZZZ"])
    assert code in (0, 1)
    assert "preflight" in capsys.readouterr().out
