"""Preflight check: is this set up, and if not, what exactly is missing?

Every failure mode in this project so far has looked the same from outside -
nothing happens, or a file that should exist does not. This answers the whole
question in one command, and says what to do about each thing it finds.

    python -m research_agent.doctor          # check everything
    python -m research_agent.doctor --probe  # also spend one cheap model call

It never trades and never writes anything except the check for a writable log
directory.
"""

from __future__ import annotations

import argparse
import importlib
import platform
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Optional

OK, WARN, FAIL, SKIP = "OK", "WARN", "FAIL", "SKIP"

_MARK = {OK: "[ok]  ", WARN: "[warn]", FAIL: "[FAIL]", SKIP: "[skip]"}


class Report:
    def __init__(self) -> None:
        self.rows: list[tuple[str, str, str, str]] = []

    def add(self, status: str, name: str, detail: str = "", fix: str = "") -> str:
        self.rows.append((status, name, detail, fix))
        return status

    @property
    def failed(self) -> int:
        return sum(1 for s, *_ in self.rows if s == FAIL)

    @property
    def warned(self) -> int:
        return sum(1 for s, *_ in self.rows if s == WARN)

    def render(self) -> str:
        lines = ["", "Market Research Agent - preflight", "=" * 66]
        for status, name, detail, fix in self.rows:
            lines.append(f"{_MARK[status]} {name}" + (f": {detail}" if detail else ""))
            if fix and status in {FAIL, WARN}:
                for line in fix.splitlines():
                    lines.append(f"        {line}")
        lines.append("=" * 66)
        if self.failed:
            lines.append(
                f"{self.failed} blocking problem(s)"
                + (f", {self.warned} warning(s)" if self.warned else "")
                + ". Fix the FAILs above, then run this again."
            )
        elif self.warned:
            lines.append(
                f"Ready to run, with {self.warned} warning(s). "
                "A dry run will work; read the warnings before using --execute."
            )
        else:
            lines.append("Everything checks out. A dry run should work.")
        return "\n".join(lines)


def _py_cmd() -> str:
    return "py -m" if platform.system() == "Windows" else "python -m"


def check_python(report: Report) -> None:
    version = sys.version_info
    detail = f"{platform.python_version()} on {platform.system()}"
    if version < (3, 9):
        report.add(FAIL, "python", detail, "This needs Python 3.9 or newer.")
    else:
        report.add(OK, "python", detail)


def check_packages(report: Report) -> None:
    needed = ["anthropic", "pydantic", "requests"]
    if platform.system() == "Windows":
        needed.append("tzdata")
    missing = [m for m in needed if not _importable(m)]
    if missing:
        report.add(
            FAIL, "dependencies", f"missing {', '.join(missing)}",
            f"{_py_cmd()} pip install -r requirements.txt",
        )
    else:
        report.add(OK, "dependencies", ", ".join(needed))


def _importable(name: str) -> bool:
    try:
        importlib.import_module(name)
        return True
    except ImportError:
        return False


def check_timezone(report: Report) -> None:
    try:
        from .config import MARKET_TZ

        now = datetime.now(timezone.utc).astimezone(MARKET_TZ)
        report.add(OK, "timezone", f"market clock reads {now:%Y-%m-%d %H:%M %Z}")
    except Exception as exc:
        report.add(
            FAIL, "timezone", str(exc)[:60],
            f"{_py_cmd()} pip install tzdata",
        )


def check_env_file(report: Report, env_file: Path) -> None:
    import os

    if env_file.exists():
        report.add(OK, ".env", str(env_file))
    else:
        report.add(
            WARN, ".env", f"not found at {env_file}",
            "Credentials can also come from the environment. To use a file:\n"
            + ("Copy-Item .env.example .env" if platform.system() == "Windows"
               else "cp .env.example .env"),
        )

    for var, what in [
        ("ANTHROPIC_API_KEY", "the reasoning step"),
        ("APCA_API_KEY_ID", "market data and account"),
        ("APCA_API_SECRET_KEY", "market data and account"),
    ]:
        value = os.getenv(var, "")
        if not value:
            report.add(FAIL, var, "not set", f"Needed for {what}. Add it to .env.")
        elif value.strip() in {"", "sk-ant-...", "..."}:
            report.add(FAIL, var, "still the placeholder", "Replace it with a real key.")
        else:
            report.add(OK, var, f"set ({len(value)} chars)")


def check_policy(report: Report) -> None:
    try:
        from .config import AgentSettings

        settings = AgentSettings.from_env()
        risk = settings.risk
        report.add(
            OK, "risk policy",
            f"trade {risk.max_risk_pct:.0%} / cluster {risk.max_cluster_risk_pct:.0%} / "
            f"book {risk.max_portfolio_risk_pct:.0%} / day {risk.max_daily_drawdown_pct:.0%}",
        )
        if settings.alpaca.is_paper:
            report.add(OK, "endpoint", f"paper ({settings.alpaca.trading_base_url})")
        elif settings.allow_live_trading:
            report.add(
                WARN, "endpoint", "LIVE, and live trading is enabled",
                "Orders will use real money. Set ALLOW_LIVE_TRADING=false to stop that.",
            )
        else:
            report.add(
                WARN, "endpoint", "live URL, but live trading is disabled",
                "Orders would be refused. Point ALPACA_TRADING_BASE_URL at "
                "https://paper-api.alpaca.markets",
            )
    except Exception as exc:
        report.add(FAIL, "risk policy", str(exc)[:70], "Check the values in .env.")


def check_broker(report: Report) -> Optional[object]:
    try:
        from .alpaca_client import AlpacaHTTP
        from .broker import AlpacaBroker
        from .config import AgentSettings

        settings = AgentSettings.from_env()
        broker = AlpacaBroker(AlpacaHTTP(settings.alpaca), settings)
        account = broker.account()
    except Exception as exc:
        report.add(
            FAIL, "alpaca account", str(exc)[:70],
            "Check APCA_API_KEY_ID and APCA_API_SECRET_KEY. Paper keys start PK.",
        )
        return None

    report.add(
        OK, "alpaca account",
        f"{account.account_number} equity {account.equity:,.2f}",
    )
    if account.trading_blocked:
        report.add(FAIL, "account status", "trading_blocked is set",
                   "Alpaca has restricted this account; nothing will be placed.")
    if account.last_equity <= 0:
        report.add(
            WARN, "prior-close equity", "not reported",
            "The daily drawdown kill-switch will halt entries until this appears. "
            "A brand new account reports it after its first session close.",
        )
    return broker


def check_market_data(report: Report, symbol: str) -> None:
    try:
        from .alpaca_client import AlpacaHTTP
        from .config import AgentSettings
        from .market_data import AlpacaMarketData

        settings = AgentSettings.from_env()
        provider = AlpacaMarketData(AlpacaHTTP(settings.alpaca))
        bars = provider.bars(symbol, timeframe="1Day", limit=30)
        if len(bars) < 15:
            report.add(
                WARN, "market data", f"only {len(bars)} daily bars for {symbol}",
                "Indicators need about 15. A thin feed or a very new listing.",
            )
        else:
            report.add(OK, "market data", f"{len(bars)} daily bars for {symbol}")
    except Exception as exc:
        report.add(
            FAIL, "market data", str(exc)[:70],
            'The free feed is "iex". "sip" needs a paid subscription.',
        )


def check_session(report: Report, broker) -> None:
    try:
        from .config import AgentSettings
        from .research import evaluate_session

        settings = AgentSettings.from_env()
        clock = broker.clock() if broker else None
        session = evaluate_session(settings.risk, clock=clock)
        if session.is_tradeable:
            report.add(OK, "market session", session.detail)
        else:
            report.add(
                WARN, "market session", session.detail,
                "Outside the session the agent emits NO_TRADE without calling "
                "the model. That is correct, not a failure.",
            )
    except Exception as exc:
        report.add(WARN, "market session", str(exc)[:70])


def check_kill_switch(report: Report, broker, latch: Path) -> None:
    if broker is None:
        report.add(SKIP, "kill switch", "needs a broker connection")
        return
    try:
        from .config import AgentSettings
        from .killswitch import FileLatchStore, evaluate

        state = evaluate(
            broker.account(), AgentSettings.from_env().risk, store=FileLatchStore(latch)
        )
        if state.halts_entries:
            report.add(
                WARN, "kill switch", state.describe()[:70],
                "New positions are halted. This clears next trading day, or "
                f"{_py_cmd()} research_agent NVDA --reset-kill-switch",
            )
        else:
            report.add(OK, "kill switch", state.describe()[:70])
    except Exception as exc:
        report.add(WARN, "kill switch", str(exc)[:70])


def check_logs(report: Report, log_dir: Path) -> None:
    if not log_dir.exists():
        report.add(
            WARN, "logs", f"{log_dir} does not exist yet",
            "Created on the first scheduled run. A manual `research_agent SYMBOL` "
            "writes no logs unless you pass --journal.",
        )
        return

    decisions = sorted(log_dir.glob("decisions-*.jsonl"))
    journals = sorted(log_dir.glob("journal-*.jsonl"))
    diaries = sorted(log_dir.glob("agent-*.log"))
    if not (decisions or diaries):
        report.add(
            WARN, "logs", f"{log_dir} is empty",
            "The scheduler has not completed a pass. Check the task's last result.",
        )
        return

    count = sum(
        1 for p in decisions for line in p.read_text().splitlines() if line.strip()
    )
    detail = f"{len(decisions)} day(s), {count} decision(s)"
    if journals:
        detail += f", {len(journals)} journal(s) - scoreable"
    else:
        detail += ", no journals - cannot be scored"
    report.add(OK, "logs", detail)

    if diaries:
        tail = [
            line for line in diaries[-1].read_text().splitlines()
            if "exited" in line or "no .env" in line
        ]
        if tail:
            report.add(
                WARN, "last run", tail[-1][:70],
                "The most recent pass reported a problem.",
            )


def probe_model(report: Report) -> None:
    try:
        import anthropic

        from .config import AgentSettings

        settings = AgentSettings.from_env()
        client = anthropic.Anthropic()
        response = client.messages.create(
            model=settings.model,
            max_tokens=16,
            messages=[{"role": "user", "content": "Reply with the single word: ready"}],
        )
        text = "".join(b.text for b in response.content if b.type == "text").strip()
        report.add(OK, "claude", f"{settings.model} replied {text!r}")
    except Exception as exc:
        report.add(
            FAIL, "claude", str(exc)[:70],
            "Check ANTHROPIC_API_KEY. A revoked or rotated key fails here.",
        )


def run(args) -> Report:
    report = Report()
    check_python(report)
    check_packages(report)
    check_timezone(report)

    from .cli import load_dotenv

    env_file = Path(args.env_file)
    load_dotenv(env_file)
    check_env_file(report, env_file)
    check_policy(report)

    broker = check_broker(report)
    if broker is not None:
        check_market_data(report, args.symbol)
        check_session(report, broker)
        check_kill_switch(report, broker, Path(args.kill_switch_file))
    else:
        report.add(SKIP, "market data", "needs working Alpaca credentials")

    check_logs(report, Path(args.log_dir))

    if args.probe:
        probe_model(report)
    else:
        report.add(SKIP, "claude", "pass --probe to spend one cheap call testing the key")
    return report


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        prog="research-agent-doctor",
        description="Check that everything needed to run is present and working.",
    )
    parser.add_argument("--symbol", default="AAPL", help="symbol used to test market data")
    parser.add_argument("--log-dir", default="logs")
    parser.add_argument("--env-file", default=".env")
    parser.add_argument("--kill-switch-file", default=".killswitch.json")
    parser.add_argument(
        "--probe", action="store_true",
        help="also make one small Claude call to prove the key works",
    )
    args = parser.parse_args(argv)

    report = run(args)
    print(report.render())
    return 1 if report.failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
