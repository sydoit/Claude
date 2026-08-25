"""A live status panel. Read-only: it never decides and never trades.

Tailing a log tells you what already happened. This answers the question you
actually have while a schedule is running: where does the account stand right
now, how much risk is open, is the kill-switch armed, and what has it decided
today.

    python -m research_agent.watch                 # live, refreshing
    python -m research_agent.watch --logs-only     # no broker, no keys needed
    python -m research_agent.watch --once          # one frame, for a pipe

It calls Alpaca for account state and never calls Claude, so watching costs
nothing beyond a few market-data requests per refresh.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from .config import MARKET_TZ

WIDTH = 78

# Kept deliberately small: a status panel that needs a colour legend has failed.
RESET, DIM, BOLD = "\033[0m", "\033[2m", "\033[1m"
GREEN, RED, YELLOW, CYAN = "\033[32m", "\033[31m", "\033[33m", "\033[36m"


class Paint:
    def __init__(self, enabled: bool) -> None:
        self.enabled = enabled

    def __call__(self, text: str, colour: str) -> str:
        return f"{colour}{text}{RESET}" if self.enabled else text


def _rule(title: str = "") -> str:
    if not title:
        return "-" * WIDTH
    return f"{title} " + "-" * max(WIDTH - len(title) - 1, 0)


def _money(value: float) -> str:
    return f"{value:,.2f}"


class BarCache:
    """Daily bars do not change intraday, so fetch them once and reuse.

    Without real history the correlation layer groups every position together
    as a conservative default, which is right for sizing a trade but reads as a
    false claim on a status panel. One fetch per refresh window buys an honest
    answer cheaply.
    """

    def __init__(self, ttl_seconds: float = 1800.0) -> None:
        self.ttl = ttl_seconds
        self._bars: dict[str, list] = {}
        self._fetched_at: float = 0.0
        self.measured = False

    def get(self, provider, symbols, *, lookback: int) -> dict[str, list]:
        stale = (time.monotonic() - self._fetched_at) > self.ttl
        missing = [s for s in symbols if s.upper() not in self._bars]
        if not stale and not missing:
            return self._bars

        for symbol in symbols:
            try:
                self._bars[symbol.upper()] = provider.bars(
                    symbol, timeframe="1Day", limit=lookback + 5
                )
            except Exception:
                # Leave it out: correlation then treats it as correlated with
                # everything, which is the conservative reading.
                self._bars.pop(symbol.upper(), None)
        self._fetched_at = time.monotonic()
        self.measured = bool(self._bars)
        return self._bars


def read_today(log_dir: Path, day: str) -> list[dict]:
    """Today's decisions, newest first. Prefers the journal, which has times."""
    journal = log_dir / f"journal-{day}.jsonl"
    decisions = log_dir / f"decisions-{day}.jsonl"
    rows: list[dict] = []
    source = journal if journal.exists() else decisions
    try:
        text = source.read_text()
    except OSError:
        return rows
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except ValueError:
            # Skip the bad line rather than abandoning the rest of the day. A
            # partially written last line is normal while a run is in flight.
            continue
    return list(reversed(rows))


def _decision_line(row: dict, paint: Paint) -> str:
    ts = row.get("ts")
    when = "  --  "
    if ts:
        try:
            when = datetime.fromisoformat(str(ts)).astimezone(MARKET_TZ).strftime("%H:%M")
        except ValueError:
            pass
    decision = str(row.get("decision", "?"))
    qty = row.get("qty")
    symbol = str(row.get("symbol", "?"))
    confidence = str(row.get("confidence", "?"))

    colour = {"BUY": GREEN, "SELL": CYAN}.get(decision, DIM)
    label = f"{decision}{'' if qty is None else ' ' + str(int(qty))}"
    # The veto is the interesting part when there is one.
    why = (row.get("vetoes") or [None])[0] or row.get("reasoning", "")
    return (
        f"  {when}  {paint(f'{label:<10}', colour)} {symbol:<6} "
        f"{confidence:<7}{str(why)[:38]}"
    )


def render(
    *,
    account=None,
    exposure=None,
    clusters=(),
    clusters_measured: bool = True,
    drawdown=None,
    session=None,
    decisions=(),
    policy,
    paint: Paint,
    error: Optional[str] = None,
) -> str:
    now_et = datetime.now(timezone.utc).astimezone(MARKET_TZ)
    if session is None:
        state = "unknown"
    elif session.is_tradeable:
        state = paint("market open", GREEN)
    else:
        state = paint("market closed", DIM)

    lines = [
        f"{BOLD if paint.enabled else ''}Market Research Agent - live"
        f"{RESET if paint.enabled else ''}"
        f"{'':<12}{now_et:%Y-%m-%d %H:%M:%S} ET   {state}",
        _rule(),
    ]

    if error:
        lines += [paint(f"  {error}", YELLOW), _rule()]

    if account is not None:
        pnl = drawdown.pnl if drawdown and drawdown.measurable else 0.0
        pct = drawdown.pnl_pct if drawdown and drawdown.measurable else 0.0
        colour = GREEN if pnl > 0 else (RED if pnl < 0 else DIM)
        lines.append(
            f"  ACCOUNT      equity {_money(account.equity):<14}"
            f"day P&L {paint(f'{pnl:+,.2f} ({pct:+.2%})', colour)}"
        )
        lines.append(
            f"               buying power {_money(account.buying_power)}"
        )

    if drawdown is not None:
        if drawdown.halts_entries:
            lines.append(
                f"  KILL SWITCH  {paint('TRIPPED - new positions halted', RED)}"
            )
        else:
            left = max(drawdown.start_equity * drawdown.limit_pct + drawdown.pnl, 0.0)
            lines.append(
                f"  KILL SWITCH  {paint('ok', GREEN)} - {_money(left)} of the "
                f"{drawdown.limit_pct:.0%} daily budget left"
            )

    if exposure is not None:
        pct = exposure.risk_pct()
        colour = RED if pct >= policy.max_portfolio_risk_pct else GREEN
        lines.append(
            f"  RISK         open {_money(exposure.total_risk)} "
            f"({paint(f'{pct:.2%}', colour)} of {policy.max_portfolio_risk_pct:.0%} cap)"
            f"   headroom {_money(exposure.headroom(policy))}"
        )
        for unprotected in exposure.unprotected:
            lines.append(
                paint(f"               ! {unprotected.symbol} has no stop", YELLOW)
            )

    grouped = [c for c in clusters if len(c.members) > 1]
    if grouped:
        lines.append(
            _rule("CLUSTERS" if clusters_measured else "CLUSTERS (unmeasured)")
        )
        if not clusters_measured:
            lines.append(
                paint("  no price history loaded; grouped conservatively", YELLOW)
            )
        for cluster in sorted(grouped, key=lambda c: c.total_risk, reverse=True)[:4]:
            over = cluster.total_risk / account.portfolio_value if account else 0
            colour = RED if over >= policy.max_cluster_risk_pct else DIM
            lines.append(
                f"  {cluster.label:<28} {_money(cluster.total_risk):>10}  "
                f"{paint(f'{over:.2%}', colour)} of {policy.max_cluster_risk_pct:.0%}"
            )

    if exposure is not None:
        lines.append(_rule("POSITIONS"))
        if not exposure.positions:
            lines.append(f"  {DIM if paint.enabled else ''}flat{RESET if paint.enabled else ''}")
        for position in exposure.positions[:8]:
            lines.append(f"  {position.describe()[:WIDTH - 4]}")

    lines.append(_rule(f"DECISIONS TODAY ({len(decisions)})"))
    if not decisions:
        lines.append("  (none yet)")
    for row in list(decisions)[:8]:
        lines.append(_decision_line(row, paint))

    lines += [_rule(), f"  {DIM if paint.enabled else ''}Ctrl-C to stop. "
              f"This view never trades.{RESET if paint.enabled else ''}"]
    return "\n".join(lines)


_BARS = BarCache()


def _frame(args, settings, paint: Paint) -> str:
    from .research import evaluate_session

    log_dir = Path(args.log_dir)
    day = datetime.now(timezone.utc).astimezone(MARKET_TZ).date().isoformat()
    decisions = read_today(log_dir, day)

    if args.logs_only:
        return render(
            policy=settings.risk, paint=paint, decisions=decisions,
            session=evaluate_session(settings.risk),
            error="logs-only: no broker connection, showing the log only",
        )

    from .alpaca_client import AlpacaError, AlpacaHTTP
    from .broker import AlpacaBroker
    from .killswitch import FileLatchStore, evaluate as evaluate_drawdown
    from .portfolio import assess, cluster_book

    try:
        http = AlpacaHTTP(settings.alpaca)
        broker = AlpacaBroker(http, settings)
        account = broker.account()
        exposure = assess(broker.positions(), broker.open_orders(), account.portfolio_value)
        clock = broker.clock()
    except (AlpacaError, ValueError) as exc:
        return render(
            policy=settings.risk, paint=paint, decisions=decisions,
            session=evaluate_session(settings.risk),
            error=f"broker unreachable: {str(exc)[:60]}",
        )

    drawdown = evaluate_drawdown(
        account, settings.risk, store=FileLatchStore(args.kill_switch_file)
    )
    clusters, measured = [], True
    if exposure.positions:
        from .market_data import AlpacaMarketData

        bars = _BARS.get(
            AlpacaMarketData(http),
            [p.symbol for p in exposure.positions],
            lookback=settings.risk.correlation_lookback,
        )
        measured = _BARS.measured
        clusters = cluster_book(exposure, bars, settings.risk)

    return render(
        account=account, exposure=exposure, clusters=clusters,
        clusters_measured=measured, drawdown=drawdown,
        session=evaluate_session(settings.risk, clock=clock),
        decisions=decisions, policy=settings.risk, paint=paint,
    )


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        prog="research-agent-watch",
        description="Live, read-only status panel. Never decides, never trades.",
    )
    parser.add_argument("log_dir", nargs="?", default="logs")
    parser.add_argument("--interval", type=float, default=15.0, help="seconds between refreshes")
    parser.add_argument("--once", action="store_true", help="render one frame and exit")
    parser.add_argument("--logs-only", action="store_true", help="do not contact the broker")
    parser.add_argument("--no-color", action="store_true")
    parser.add_argument("--kill-switch-file", default=".killswitch.json")
    parser.add_argument("--env-file", default=".env")
    args = parser.parse_args(argv)

    from .cli import load_dotenv
    from .config import AgentSettings, ConfigError

    load_dotenv(Path(args.env_file))
    try:
        settings = AgentSettings.from_env()
    except (ConfigError, ValueError) as exc:
        print(f"configuration error: {exc}", file=sys.stderr)
        return 2

    import os

    paint = Paint(
        not args.no_color and not os.getenv("NO_COLOR") and sys.stdout.isatty()
    )

    if args.once:
        print(_frame(args, settings, paint))
        return 0

    try:
        while True:
            frame = _frame(args, settings, paint)
            # Home and clear, rather than a scroll-blanking newline flood.
            sys.stdout.write("\033[H\033[J" + frame + "\n")
            sys.stdout.flush()
            time.sleep(max(args.interval, 2.0))
    except KeyboardInterrupt:
        print()
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
