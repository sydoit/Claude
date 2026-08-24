"""Command line entry point.

The spec's JSON decision goes to stdout and nothing else does, so the command
composes with `jq`. Everything human-facing goes to stderr.
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
from pathlib import Path
from typing import Optional

from .alpaca_client import AlpacaError, AlpacaHTTP
from .broker import Account, AlpacaBroker, LiveTradingBlocked, MarketClock
from .config import AgentSettings, ConfigError
from .execution import ExecutionReport, execute
from .guardrails import review
from .indicators import InsufficientData
from .llm import propose_decision
from .market_data import FixtureMarketData
from .portfolio import assess_from_broker
from .research import build_brief
from .schema import no_trade

log = logging.getLogger("research_agent")


def load_dotenv(path: Path) -> None:
    """Minimal .env reader. Existing environment variables always win."""
    if not path.exists():
        return
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key, value = key.strip(), value.strip().strip("'\"")
        os.environ.setdefault(key, value)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="research-agent",
        description="Research a symbol with Claude and place the trade on Alpaca paper.",
    )
    p.add_argument("symbol", help="ticker to analyse, e.g. NVDA")
    p.add_argument(
        "--execute",
        action="store_true",
        help="actually submit the order. Without this the run is a dry run.",
    )
    p.add_argument("--timeframe", default="1Day", help="bar timeframe (default 1Day)")
    p.add_argument("--bars", type=int, default=120, help="how many bars to pull")
    p.add_argument(
        "--offline",
        metavar="CSV",
        help="read bars from a CSV instead of Alpaca (implies no execution)",
    )
    p.add_argument(
        "--portfolio-value",
        type=float,
        help="override portfolio value (required with --offline)",
    )
    p.add_argument("--env-file", default=".env", help="path to the .env file")
    p.add_argument("-v", "--verbose", action="store_true", help="debug logging")
    return p


def _resolve_account_and_clock(
    args: argparse.Namespace, broker: Optional[AlpacaBroker]
) -> tuple[Account, Optional[MarketClock]]:
    if broker is None:
        pv = args.portfolio_value
        if pv is None:
            raise ConfigError("--offline requires --portfolio-value")
        return (
            Account(
                account_number="OFFLINE",
                portfolio_value=pv,
                buying_power=pv * 2,
                cash=pv,
                equity=pv,
                trading_blocked=False,
                pattern_day_trader=False,
            ),
            None,
        )
    account = broker.account()
    if args.portfolio_value is not None:
        account = Account(**{**account.__dict__, "portfolio_value": args.portfolio_value})
    return account, broker.clock()


def _report(report: ExecutionReport) -> None:
    if report.error:
        print(f"[execution] FAILED: {report.intent}\n           {report.error}", file=sys.stderr)
    elif report.dry_run:
        print(f"[execution] DRY RUN - would {report.action}: {report.intent}", file=sys.stderr)
        print("[execution] re-run with --execute to submit this order.", file=sys.stderr)
    elif report.order:
        o = report.order
        print(
            f"[execution] SUBMITTED ({report.action}): {report.intent}\n"
            f"            order {o.id} status={o.status} class={o.order_class}",
            file=sys.stderr,
        )
    else:
        print(f"[execution] {report.action}: {report.intent}", file=sys.stderr)


def main(argv: Optional[list[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s %(name)s: %(message)s",
        stream=sys.stderr,
    )
    load_dotenv(Path(args.env_file))

    symbol = args.symbol.strip().upper()
    try:
        settings = AgentSettings.from_env()
    except (ConfigError, ValueError) as exc:
        print(f"configuration error: {exc}", file=sys.stderr)
        return 2

    broker: Optional[AlpacaBroker] = None
    try:
        if args.offline:
            provider = FixtureMarketData.from_csv(args.offline)
        else:
            http = AlpacaHTTP(settings.alpaca)
            broker = AlpacaBroker(http, settings)
            from .market_data import AlpacaMarketData

            provider = AlpacaMarketData(http)

        account, clock = _resolve_account_and_clock(args, broker)
        position = broker.position(symbol) if broker else None
        exposure = (
            assess_from_broker(broker, account.portfolio_value) if broker else None
        )

        brief = build_brief(
            symbol,
            provider=provider,
            policy=settings.risk,
            account=account,
            position=position,
            clock=clock,
            exposure=exposure,
            timeframe=args.timeframe,
            bar_limit=args.bars,
        )
    except (ConfigError, InsufficientData, AlpacaError, ValueError, OSError, KeyError) as exc:
        # Unreadable file, malformed payload, thin history, bad credentials:
        # Cannot research it -> cannot judge it -> do not trade it.
        decision = no_trade(symbol, f"No trade: could not assemble market research ({exc}).")
        print(decision.to_json())
        print(f"[error] {exc}", file=sys.stderr)
        return 1

    print(f"[research] {brief.session.detail}", file=sys.stderr)
    if brief.exposure is not None and brief.exposure.positions:
        print(
            f"[research] portfolio risk {brief.exposure.total_risk:,.2f} "
            f"({brief.exposure.risk_pct():.2%} of the "
            f"{settings.risk.max_portfolio_risk_pct:.2%} cap), headroom "
            f"{brief.exposure.headroom(settings.risk):,.2f}",
            file=sys.stderr,
        )
        for unprotected in brief.exposure.unprotected:
            print(
                f"[research] WARNING: {unprotected.symbol} has no working stop; "
                f"its full {unprotected.risk_amount:,.2f} notional counts as at risk",
                file=sys.stderr,
            )

    outcome = propose_decision(brief, settings)
    if outcome.failed:
        print(f"[model] {outcome.error}", file=sys.stderr)
    else:
        print(
            f"[model] proposed {outcome.decision.decision} "
            f"qty={outcome.decision.qty} confidence={outcome.decision.confidence}",
            file=sys.stderr,
        )

    result = review(
        outcome.decision,
        brief,
        settings.risk,
        trading_blocked=account.trading_blocked,
        requested_symbol=symbol,
    )
    for note in result.adjustments:
        print(f"[guardrail] adjusted: {note}", file=sys.stderr)
    for veto in result.vetoes:
        print(f"[guardrail] VETO: {veto}", file=sys.stderr)

    # The spec's contract: exactly this object, on stdout, always.
    print(result.decision.to_json())

    if not result.approved:
        return 0

    if broker is None:
        print("[execution] offline mode: nothing submitted.", file=sys.stderr)
        return 0

    try:
        report = execute(
            result.decision, result.plan, brief, broker, dry_run=not args.execute
        )
    except LiveTradingBlocked as exc:
        print(f"[execution] BLOCKED: {exc}", file=sys.stderr)
        return 3
    _report(report)
    return 0 if report.action != "failed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
