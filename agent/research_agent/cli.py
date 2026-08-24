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
from .journal import append as journal_append, build_record
from .killswitch import (
    DEFAULT_LATCH_FILE,
    FileLatchStore,
    NullLatchStore,
    evaluate as evaluate_drawdown,
)
from .indicators import InsufficientData
from .llm import propose_decision
from .market_data import FixtureMarketData
from .correlation import load_static_groups
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
    p.add_argument(
        "--correlation-groups",
        metavar="JSON",
        help='optional {"group": ["SYM", ...]} file declaring symbols as correlated',
    )
    p.add_argument(
        "--kill-switch-file",
        default=DEFAULT_LATCH_FILE,
        help=f"where the tripped kill-switch is recorded (default {DEFAULT_LATCH_FILE})",
    )
    p.add_argument(
        "--reset-kill-switch",
        action="store_true",
        help="clear a tripped kill-switch and exit, re-arming it for today",
    )
    p.add_argument(
        "--journal",
        metavar="JSONL",
        help="append a scoreable record of this decision (entry, stop, target)",
    )
    p.add_argument(
        "--compact",
        action="store_true",
        help="emit the decision as one JSON line, for appending to a log",
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
                # Offline runs have no P&L history, so the day is flat by
                # definition. Without this the kill-switch would read the
                # missing baseline as unmeasurable and halt every dry run.
                last_equity=pv,
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

    if args.reset_kill_switch:
        FileLatchStore(args.kill_switch_file).clear()
        print(
            f"[kill-switch] cleared {args.kill_switch_file}; entries are re-armed "
            "for today.",
            file=sys.stderr,
        )
        return 0

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

        # The latch is only meaningful against a real account.
        drawdown = evaluate_drawdown(
            account,
            settings.risk,
            store=FileLatchStore(args.kill_switch_file) if broker else NullLatchStore(),
        )
        position = broker.position(symbol) if broker else None
        exposure = (
            assess_from_broker(broker, account.portfolio_value) if broker else None
        )

        # Correlation needs history for every open position, not just the
        # candidate. A symbol whose bars will not load is left out, and the
        # correlation layer then treats it as correlated with everything.
        peer_bars = {}
        if exposure is not None:
            for held in exposure.positions:
                if held.symbol.upper() == symbol:
                    continue
                try:
                    peer_bars[held.symbol.upper()] = provider.bars(
                        held.symbol,
                        timeframe=args.timeframe,
                        limit=settings.risk.correlation_lookback + 5,
                    )
                except Exception as exc:
                    log.warning("no bars for %s: %s", held.symbol, exc)

        brief = build_brief(
            symbol,
            provider=provider,
            policy=settings.risk,
            account=account,
            position=position,
            clock=clock,
            exposure=exposure,
            drawdown=drawdown,
            peer_bars=peer_bars,
            static_groups=load_static_groups(args.correlation_groups),
            timeframe=args.timeframe,
            bar_limit=args.bars,
        )
    except (ConfigError, InsufficientData, AlpacaError, ValueError, OSError, KeyError) as exc:
        # Unreadable file, malformed payload, thin history, bad credentials:
        # Cannot research it -> cannot judge it -> do not trade it.
        decision = no_trade(symbol, f"No trade: could not assemble market research ({exc}).")
        print(decision.to_json(indent=None if args.compact else 2))
        print(f"[error] {exc}", file=sys.stderr)
        return 1

    print(f"[research] {brief.session.detail}", file=sys.stderr)
    if brief.drawdown is not None:
        marker = "HALTED" if brief.drawdown.halts_entries else "ok"
        print(f"[kill-switch] {marker}: {brief.drawdown.describe()}", file=sys.stderr)
    if brief.exposure is not None and brief.exposure.positions:
        print(
            f"[research] portfolio risk {brief.exposure.total_risk:,.2f} "
            f"({brief.exposure.risk_pct():.2%} of the "
            f"{settings.risk.max_portfolio_risk_pct:.2%} cap), headroom "
            f"{brief.exposure.headroom(settings.risk):,.2f}",
            file=sys.stderr,
        )
        for cluster in sorted(
            brief.clusters, key=lambda c: c.total_risk, reverse=True
        ):
            if len(cluster.members) > 1:
                print(
                    f"[research] cluster "
                    f"{cluster.describe(brief.portfolio_value, settings.risk)}",
                    file=sys.stderr,
                )
        for unprotected in brief.exposure.unprotected:
            print(
                f"[research] WARNING: {unprotected.symbol} has no working stop; "
                f"its full {unprotected.risk_amount:,.2f} notional counts as at risk",
                file=sys.stderr,
            )

    indent = None if args.compact else 2

    # Nothing can be acted on outside the session — not even an exit — so the
    # clock alone settles it. Skipping the model here is what keeps a schedule
    # that fires on holidays and half-days from costing anything.
    if not brief.session.is_tradeable:
        print(
            no_trade(
                symbol,
                f"No trade: the market is not in its regular session "
                f"({brief.session.detail}).",
            ).to_json(indent=indent)
        )
        print("[model] skipped: market closed, no call made", file=sys.stderr)
        return 0

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
    print(result.decision.to_json(indent=indent))

    def journal(report: Optional[ExecutionReport] = None) -> None:
        if args.journal:
            journal_append(
                args.journal,
                build_record(
                    brief, result,
                    proposed_qty=outcome.decision.qty,
                    proposed_confidence=outcome.decision.confidence,
                    report=report,
                ),
            )

    if not result.approved:
        journal()
        return 0

    if broker is None:
        journal()
        print("[execution] offline mode: nothing submitted.", file=sys.stderr)
        return 0

    try:
        report = execute(
            result.decision, result.plan, brief, broker, dry_run=not args.execute
        )
    except LiveTradingBlocked as exc:
        journal()
        print(f"[execution] BLOCKED: {exc}", file=sys.stderr)
        return 3
    journal(report)
    _report(report)
    return 0 if report.action != "failed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
