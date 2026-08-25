"""Scan a watchlist in one pass.

The single-symbol command re-fetches the account, positions, orders and clock
every time it runs, which is fine for one symbol and wasteful for twenty. This
fetches that state once, screens the watchlist against it, and spends its model
budget on what is left.

    python -m research_agent.scan NVDA AAPL MSFT
    python -m research_agent.scan --watchlist watchlist.txt --budget 5
    python -m research_agent.scan --watchlist watchlist.txt --execute
"""

from __future__ import annotations

import argparse
import logging
import sys
import time
from pathlib import Path
from typing import Optional

from .alpaca_client import AlpacaError, AlpacaHTTP
from .broker import AlpacaBroker, LiveTradingBlocked
from .cli import load_dotenv
from .config import AgentSettings, ConfigError
from .correlation import load_static_groups
from .execution import execute
from .guardrails import review
from .indicators import InsufficientData
from .journal import append as journal_append, build_record
from .killswitch import FileLatchStore, evaluate as evaluate_drawdown
from .llm import propose_decision
from .market_data import AlpacaMarketData
from .portfolio import assess_from_broker
from .research import build_brief
from .schema import no_trade
from .screen import screen

log = logging.getLogger("research_agent.scan")


def read_watchlist(path: str | Path) -> list[str]:
    """One symbol per line. Blank lines and # comments ignored."""
    symbols: list[str] = []
    for line in Path(path).read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            symbols.extend(s.strip().upper() for s in line.replace(",", " ").split())
    seen, unique = set(), []
    for symbol in symbols:
        if symbol not in seen:
            seen.add(symbol)
            unique.append(symbol)
    return unique


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="research-agent-scan",
        description="Research a watchlist in one pass, spending model calls where they count.",
    )
    p.add_argument("symbols", nargs="*", help="symbols to scan")
    p.add_argument("--watchlist", metavar="FILE", help="file of symbols, one per line")
    p.add_argument(
        "--budget", type=int, default=5,
        help="most model calls this pass may spend (default 5, 0 for no calls)",
    )
    p.add_argument("--execute", action="store_true", help="actually submit orders")
    p.add_argument("--timeframe", default="1Day")
    p.add_argument("--bars", type=int, default=120)
    p.add_argument("--journal", metavar="JSONL")
    p.add_argument("--compact", action="store_true")
    p.add_argument("--correlation-groups", metavar="JSON")
    p.add_argument("--kill-switch-file", default=".killswitch.json")
    p.add_argument("--env-file", default=".env")
    p.add_argument("-v", "--verbose", action="store_true")
    return p


def main(argv: Optional[list[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s %(name)s: %(message)s",
        stream=sys.stderr,
    )
    load_dotenv(Path(args.env_file))

    symbols = [s.strip().upper() for s in args.symbols]
    if args.watchlist:
        try:
            symbols += read_watchlist(args.watchlist)
        except OSError as exc:
            print(f"cannot read watchlist: {exc}", file=sys.stderr)
            return 2
    symbols = list(dict.fromkeys(symbols))
    if not symbols:
        print("no symbols given; pass them as arguments or use --watchlist", file=sys.stderr)
        return 2

    indent = None if args.compact else 2
    try:
        settings = AgentSettings.from_env()
        http = AlpacaHTTP(settings.alpaca)
        broker = AlpacaBroker(http, settings)
        provider = AlpacaMarketData(http)

        # Fetched once for the whole watchlist, not once per symbol.
        account = broker.account()
        clock = broker.clock()
        exposure = assess_from_broker(broker, account.portfolio_value)
        drawdown = evaluate_drawdown(
            account, settings.risk, store=FileLatchStore(args.kill_switch_file)
        )
        groups = load_static_groups(args.correlation_groups)
    except (ConfigError, AlpacaError, ValueError) as exc:
        print(f"[error] {exc}", file=sys.stderr)
        for symbol in symbols:
            print(no_trade(symbol, f"No trade: setup failed ({exc}).").to_json(indent))
        return 1

    print(
        f"[scan] {len(symbols)} symbol(s); portfolio {account.portfolio_value:,.2f}; "
        f"{drawdown.describe()}",
        file=sys.stderr, flush=True,
    )

    held = {p.symbol.upper() for p in exposure.positions}
    peer_bars: dict[str, list] = {}
    briefs = {}
    for symbol in symbols:
        try:
            brief = build_brief(
                symbol, provider=provider, policy=settings.risk, account=account,
                position=broker.position(symbol) if symbol in held else None,
                clock=clock, exposure=exposure, drawdown=drawdown,
                peer_bars=peer_bars, static_groups=groups,
                timeframe=args.timeframe, bar_limit=args.bars,
            )
        except (InsufficientData, AlpacaError, ValueError) as exc:
            print(f"[scan] {symbol}: no research ({exc})", file=sys.stderr)
            print(no_trade(symbol, f"No trade: could not research {symbol} ({exc}).")
                  .to_json(indent))
            continue
        briefs[symbol] = brief
        # Each symbol's bars feed the next symbol's correlation check.
        peer_bars[symbol] = provider.bars(
            symbol, timeframe=args.timeframe, limit=settings.risk.correlation_lookback + 5
        ) if symbol not in peer_bars else peer_bars[symbol]

    candidates, skipped = screen(
        briefs, settings.risk, drawdown=drawdown, budget=args.budget
    )

    for entry in skipped:
        print(f"[screen] {entry.describe()}", file=sys.stderr)
        print(no_trade(entry.symbol, f"No trade: {entry.skip_reason}.").to_json(indent))

    if not candidates:
        print("[scan] nothing worth a model call this pass", file=sys.stderr)
        return 0

    print(
        f"[scan] asking about {len(candidates)}: "
        + ", ".join(f"{c.symbol}({c.score:.2f})" for c in candidates),
        file=sys.stderr, flush=True,
    )

    status = 0
    for entry in candidates:
        brief = entry.brief
        started = time.monotonic()
        outcome = propose_decision(brief, settings)
        elapsed = time.monotonic() - started
        if outcome.failed:
            print(f"[model] {entry.symbol}: {outcome.error}", file=sys.stderr)
        else:
            print(
                f"[model] {entry.symbol}: {outcome.decision.decision} "
                f"qty={outcome.decision.qty} {outcome.decision.confidence} in {elapsed:.1f}s",
                file=sys.stderr, flush=True,
            )

        result = review(
            outcome.decision, brief, settings.risk,
            trading_blocked=account.trading_blocked, requested_symbol=entry.symbol,
        )
        for veto in result.vetoes:
            print(f"[guardrail] {entry.symbol}: VETO {veto}", file=sys.stderr)
        print(result.decision.to_json(indent))

        report = None
        if result.approved:
            try:
                report = execute(
                    result.decision, result.plan, brief, broker, dry_run=not args.execute
                )
            except LiveTradingBlocked as exc:
                print(f"[execution] BLOCKED: {exc}", file=sys.stderr)
                return 3
            marker = "DRY RUN - would" if report.dry_run else report.action.upper()
            print(f"[execution] {entry.symbol}: {marker} {report.intent}", file=sys.stderr)
            if report.action == "failed":
                status = 1

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

    return status


if __name__ == "__main__":
    raise SystemExit(main())
