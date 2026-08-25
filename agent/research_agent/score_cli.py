"""`python -m research_agent.score logs/` - did the decisions actually work?"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional

from .journal import read as read_journal
from .scoring import (
    OPEN,
    STOP,
    TARGET,
    Summary,
    TradeOutcome,
    plan_from_record,
    score_all,
)


def _fmt_r(value: float) -> str:
    return f"{value:+.2f}R"


def _line(name: str, summary: Summary, width: int = 22) -> str:
    pf = summary.profit_factor
    pf_text = "n/a" if pf is None else ("inf" if pf == float("inf") else f"{pf:.2f}")
    return (
        f"  {name:<{width}} {summary.count:>4}  "
        f"{summary.win_rate:>6.0%}  "
        f"{_fmt_r(summary.expectancy):>8}  "
        f"{_fmt_r(summary.total_r):>9}  "
        f"{pf_text:>6}"
    )


def render(summary: Summary, *, horizon: int, slippage_bps: float, show: int = 30) -> str:
    unscorable = [o for o in summary.outcomes if not o.scored]
    if not summary.scored:
        return (
            "Nothing to score yet.\n"
            f"{len(unscorable)} decision(s) found, but none have bars after them. "
            "Scoring needs the market to have moved on: give it a few sessions."
        )

    header = f"  {'':<22} {'n':>4}  {'win':>6}  {'avg':>8}  {'total':>9}  {'PF':>6}"
    out = [
        "=" * 78,
        "Outcome scoring - what the decisions actually did",
        f"{summary.count} scored, {len(summary.resolved)} resolved, "
        f"horizon {horizon} bars, slippage {slippage_bps:g}bps",
        "=" * 78,
        "",
        "OVERALL",
        header,
        _line("all trades", summary),
        "",
        f"  Total P&L        {summary.total_pnl:>+14,.2f}",
        f"  Expectancy       {_fmt_r(summary.expectancy):>14}  per trade",
        f"  Avg bars held    {summary.average_bars_held:>14.1f}",
    ]

    resolution = {TARGET: 0, STOP: 0, OPEN: 0}
    for outcome in summary.scored:
        resolution[outcome.result] = resolution.get(outcome.result, 0) + 1
    out += ["", "HOW THEY ENDED"]
    labels = {TARGET: "hit target", STOP: "stopped out", OPEN: "still open at horizon"}
    for key, count in resolution.items():
        pct = count / summary.count * 100 if summary.count else 0
        out.append(f"  {labels.get(key, key):<24} {count:>4}  {pct:>5.1f}%")

    # The question worth asking of a language model: is its own confidence
    # worth anything?
    out += ["", "BY STATED CONFIDENCE", header]
    order = {"HIGH": 0, "MEDIUM": 1, "LOW": 2}
    for name, bucket in sorted(
        summary.by(lambda o: o.plan.confidence).items(),
        key=lambda kv: order.get(kv[0], 9),
    ):
        out.append(_line(name, bucket))

    out += ["", "BY SIDE", header]
    for name, bucket in summary.by(lambda o: o.plan.decision).items():
        out.append(_line(name, bucket))

    by_symbol = summary.by(lambda o: o.plan.symbol)
    if len(by_symbol) > 1:
        out += ["", "BY SYMBOL", header]
        for name, bucket in sorted(
            by_symbol.items(), key=lambda kv: kv[1].total_r, reverse=True
        ):
            out.append(_line(name, bucket))

    out += ["", f"TRADES ({min(len(summary.scored), show)} of {summary.count})"]
    out.append(
        f"  {'day':<11}{'side':<5}{'sym':<7}{'conf':<8}{'result':<13}{'R':>7}  {'P&L':>11}"
    )
    for outcome in summary.scored[:show]:
        plan = outcome.plan
        out.append(
            f"  {plan.trading_day:<11}{plan.decision:<5}{plan.symbol:<7}"
            f"{plan.confidence:<8}{outcome.result:<13}"
            f"{outcome.r_multiple:>+7.2f}  {outcome.pnl:>+11,.2f}"
        )
    if len(summary.scored) > show:
        out.append(f"  ... and {len(summary.scored) - show} more")

    same_bar = [o for o in summary.scored if "both inside one bar" in o.note]
    if same_bar or unscorable:
        out += ["", "CAVEATS"]
        if same_bar:
            out.append(
                f"  {len(same_bar)} trade(s) touched stop and target in the same bar; "
                "the stop was assumed."
            )
        if unscorable:
            out.append(
                f"  {len(unscorable)} decision(s) not yet scorable "
                "(no bars after them yet)."
            )

    out += [
        "",
        "-" * 78,
        "Expectancy is the number that matters: average R per trade. Positive and",
        "stable across enough trades is the case for going live. A handful of",
        "trades is not evidence either way, whatever the total says.",
    ]
    return "\n".join(out)


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        prog="research-agent-score",
        description="Replay journalled decisions against what the market did next.",
    )
    parser.add_argument("log_dir", nargs="?", default="logs", help="directory of journals")
    parser.add_argument(
        "--horizon", type=int, default=20,
        help="bars to wait for a stop or target before marking to market",
    )
    parser.add_argument(
        "--slippage-bps", type=float, default=0.0,
        help="basis points charged against entry and exit",
    )
    parser.add_argument("--timeframe", default="1Day", help="bar timeframe to score on")
    parser.add_argument("--trades", type=int, default=30, help="how many trades to list")
    parser.add_argument("--json", action="store_true", help="emit the summary as JSON")
    parser.add_argument(
        "--offline", metavar="CSV",
        help="score against a CSV of bars instead of Alpaca (one symbol only)",
    )
    parser.add_argument("--env-file", default=".env", help="path to the .env file")
    args = parser.parse_args(argv)

    log_dir = Path(args.log_dir)
    if not log_dir.is_dir():
        print(f"no such log directory: {log_dir}", file=sys.stderr)
        return 1

    records: list[dict] = []
    for path in sorted(log_dir.glob("journal-*.jsonl")):
        records.extend(read_journal(path))
    if not records:
        print(
            f"no journal files in {log_dir}. Scheduled runs write journal-*.jsonl; "
            "older runs predating the journal cannot be scored.",
            file=sys.stderr,
        )
        return 1

    plans = [p for p in (plan_from_record(r) for r in records) if p is not None]
    if not plans:
        print(
            f"{len(records)} journalled decision(s), none of them trades to score.",
            file=sys.stderr,
        )
        return 0

    symbols = sorted({p.symbol for p in plans})
    earliest = min(p.ts for p in plans)

    bars_by_symbol: dict[str, list] = {}
    if args.offline:
        from .market_data import FixtureMarketData

        provider = FixtureMarketData.from_csv(args.offline)
        for symbol in symbols:
            bars_by_symbol[symbol] = provider.bars(symbol, limit=10_000)
    else:
        from .cli import load_dotenv
        from .alpaca_client import AlpacaError, AlpacaHTTP
        from .config import AgentSettings, ConfigError
        from .market_data import AlpacaMarketData

        load_dotenv(Path(args.env_file))
        try:
            settings = AgentSettings.from_env()
            provider = AlpacaMarketData(AlpacaHTTP(settings.alpaca))
        except (ConfigError, ValueError) as exc:
            print(f"cannot reach market data: {exc}", file=sys.stderr)
            return 2
        # Fetch generously past the horizon so every trade can resolve.
        start = earliest - timedelta(days=2)
        end = datetime.now(timezone.utc)
        for symbol in symbols:
            try:
                bars_by_symbol[symbol] = provider.bars(
                    symbol, timeframe=args.timeframe,
                    limit=max(args.horizon * 4, 200), start=start, end=end,
                )
            except (AlpacaError, ValueError) as exc:
                print(f"no bars for {symbol}: {exc}", file=sys.stderr)
                bars_by_symbol[symbol] = []

    summary = score_all(
        plans, bars_by_symbol,
        horizon=args.horizon, slippage_bps=args.slippage_bps,
    )

    if args.json:
        print(json.dumps(_as_json(summary, horizon=args.horizon,
                                  slippage_bps=args.slippage_bps), indent=2))
    else:
        print(render(summary, horizon=args.horizon,
                     slippage_bps=args.slippage_bps, show=args.trades))
    return 0


def _as_json(summary: Summary, *, horizon: int, slippage_bps: float) -> dict:
    def bucket(s: Summary) -> dict:
        pf = s.profit_factor
        return {
            "count": s.count,
            "win_rate": round(s.win_rate, 4),
            "expectancy_r": round(s.expectancy, 4),
            "total_r": round(s.total_r, 4),
            "total_pnl": round(s.total_pnl, 2),
            "profit_factor": None if pf is None else (
                "inf" if pf == float("inf") else round(pf, 4)
            ),
        }

    return {
        "horizon": horizon,
        "slippage_bps": slippage_bps,
        "overall": bucket(summary),
        "by_confidence": {k: bucket(v) for k, v in summary.by(lambda o: o.plan.confidence).items()},
        "by_side": {k: bucket(v) for k, v in summary.by(lambda o: o.plan.decision).items()},
        "by_symbol": {k: bucket(v) for k, v in summary.by(lambda o: o.plan.symbol).items()},
        "trades": [
            {
                "trading_day": o.plan.trading_day,
                "symbol": o.plan.symbol,
                "decision": o.plan.decision,
                "confidence": o.plan.confidence,
                "qty": o.plan.qty,
                "result": o.result,
                "r_multiple": round(o.r_multiple, 4),
                "pnl": round(o.pnl, 2),
                "bars_held": o.bars_held,
                "note": o.note,
            }
            for o in summary.scored
        ],
        "unscorable": len([o for o in summary.outcomes if not o.scored]),
    }


if __name__ == "__main__":
    raise SystemExit(main())
