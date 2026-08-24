"""Replay journalled decisions against what the market actually did.

The review tool says what the agent decided. This says whether it was right.

Each entry is walked forward bar by bar from the first bar that opens *after*
the decision, asking which came first: the protective stop or the target. The
answer is reported in **R** - multiples of the risk taken - which is the only
unit that lets a 131-share trade in a $100 stock be compared with an 8-share
trade in a $2,000 one. Risk is 1R by construction, so a target hit at 2:1 is
+2R and a stop is -1R, and summing R across trades is meaningful.

Three modelling choices, all deliberately pessimistic:

* **Same-bar ambiguity resolves to the stop.** When a bar's range covers both
  the stop and the target there is no way to know which was touched first, so
  the loss is assumed. Guessing the other way would flatter every result.
* **Scoring starts at the next bar.** Using the decision's own bar would score
  against price action that had already happened when the call was made.
* **Slippage is charged on entry and exit**, off by default because the honest
  value depends on your broker and your symbols.

What this is not: a backtest. It scores the decisions that were actually made,
on the symbols that were actually watched. It cannot tell you what a different
watchlist would have done, it does not model overlapping positions competing
for capital, and it assumes every order filled at the reference price.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from datetime import datetime
from statistics import mean
from typing import Iterable, Mapping, Optional, Sequence

from .indicators import Bar

TARGET = "target"
STOP = "stop"
OPEN = "open"
UNSCORABLE = "unscorable"


@dataclass(frozen=True)
class TradePlan:
    """A journalled decision with enough detail to replay."""

    ts: datetime
    trading_day: str
    symbol: str
    decision: str
    qty: float
    confidence: str
    entry: float
    stop: float
    target: float
    stop_distance: float
    executed: bool
    reasoning: str = ""

    @property
    def is_long(self) -> bool:
        return self.decision == "BUY"


@dataclass(frozen=True)
class TradeOutcome:
    plan: TradePlan
    result: str
    exit_price: float
    exit_ts: Optional[datetime]
    bars_held: int
    r_multiple: float
    pnl: float
    note: str = ""

    @property
    def is_win(self) -> bool:
        return self.r_multiple > 0

    @property
    def scored(self) -> bool:
        return self.result != UNSCORABLE


def plan_from_record(record: Mapping) -> Optional[TradePlan]:
    """Build a plan from a journal record, or None if it cannot be scored."""
    if record.get("decision") not in {"BUY", "SELL"}:
        return None
    required = ("entry", "stop", "target", "stop_distance", "qty", "ts")
    if any(record.get(key) in (None, "") for key in required):
        return None
    try:
        stop_distance = float(record["stop_distance"])
        if stop_distance <= 0:
            return None
        return TradePlan(
            ts=datetime.fromisoformat(str(record["ts"])),
            trading_day=str(record.get("trading_day", "")),
            symbol=str(record["symbol"]).upper(),
            decision=str(record["decision"]),
            qty=float(record["qty"]),
            confidence=str(record.get("confidence", "?")),
            entry=float(record["entry"]),
            stop=float(record["stop"]),
            target=float(record["target"]),
            stop_distance=stop_distance,
            executed=bool(record.get("executed")),
            reasoning=str(record.get("reasoning", "")),
        )
    except (TypeError, ValueError):
        return None


def _slipped(price: float, *, bps: float, against: int) -> float:
    """Move a price against the trade by `bps` basis points."""
    return price * (1 + against * bps / 10_000)


def score_trade(
    plan: TradePlan,
    bars: Sequence[Bar],
    *,
    horizon: int = 20,
    slippage_bps: float = 0.0,
) -> TradeOutcome:
    """Walk forward from the decision and see which side was reached first."""
    forward = [b for b in bars if b.ts > plan.ts][:horizon]
    if not forward:
        return TradeOutcome(
            plan=plan, result=UNSCORABLE, exit_price=plan.entry, exit_ts=None,
            bars_held=0, r_multiple=0.0, pnl=0.0,
            note="no bars after the decision yet",
        )

    direction = 1 if plan.is_long else -1
    # Entry slips against you: a buy fills higher, a sell lower.
    entry = _slipped(plan.entry, bps=slippage_bps, against=direction)

    for index, bar in enumerate(forward, start=1):
        hit_stop = bar.low <= plan.stop if plan.is_long else bar.high >= plan.stop
        hit_target = bar.high >= plan.target if plan.is_long else bar.low <= plan.target

        if hit_stop or hit_target:
            # Both inside one bar: the intrabar path is unknowable, so assume
            # the loss. Assuming the win would flatter every number here.
            took_stop = hit_stop
            raw_exit = plan.stop if took_stop else plan.target
            exit_price = _slipped(raw_exit, bps=slippage_bps, against=-direction)
            pnl = (exit_price - entry) * direction * plan.qty
            return TradeOutcome(
                plan=plan,
                result=STOP if took_stop else TARGET,
                exit_price=exit_price,
                exit_ts=bar.ts,
                bars_held=index,
                r_multiple=pnl / (plan.stop_distance * plan.qty),
                pnl=pnl,
                note="stop and target both inside one bar; stop assumed"
                if (hit_stop and hit_target)
                else "",
            )

    # Neither side reached inside the horizon: mark to the last close.
    last = forward[-1]
    exit_price = _slipped(last.close, bps=slippage_bps, against=-direction)
    pnl = (exit_price - entry) * direction * plan.qty
    return TradeOutcome(
        plan=plan, result=OPEN, exit_price=exit_price, exit_ts=last.ts,
        bars_held=len(forward), r_multiple=pnl / (plan.stop_distance * plan.qty),
        pnl=pnl, note=f"still open after {len(forward)} bars; marked to close",
    )


@dataclass
class Summary:
    outcomes: list[TradeOutcome]

    @property
    def scored(self) -> list[TradeOutcome]:
        return [o for o in self.outcomes if o.scored]

    @property
    def resolved(self) -> list[TradeOutcome]:
        """Trades that actually reached a stop or a target."""
        return [o for o in self.scored if o.result in {STOP, TARGET}]

    @property
    def count(self) -> int:
        return len(self.scored)

    @property
    def wins(self) -> list[TradeOutcome]:
        return [o for o in self.scored if o.is_win]

    @property
    def win_rate(self) -> float:
        return len(self.wins) / self.count if self.count else 0.0

    @property
    def total_r(self) -> float:
        return sum(o.r_multiple for o in self.scored)

    @property
    def expectancy(self) -> float:
        """Average R per trade. The number that decides whether to go live."""
        return self.total_r / self.count if self.count else 0.0

    @property
    def total_pnl(self) -> float:
        return sum(o.pnl for o in self.scored)

    @property
    def profit_factor(self) -> Optional[float]:
        gains = sum(o.r_multiple for o in self.scored if o.r_multiple > 0)
        losses = -sum(o.r_multiple for o in self.scored if o.r_multiple < 0)
        if losses <= 0:
            return None if gains <= 0 else math.inf
        return gains / losses

    @property
    def average_bars_held(self) -> float:
        held = [o.bars_held for o in self.scored]
        return mean(held) if held else 0.0

    def by(self, key) -> dict[str, "Summary"]:
        buckets: dict[str, list[TradeOutcome]] = {}
        for outcome in self.scored:
            buckets.setdefault(key(outcome), []).append(outcome)
        return {k: Summary(v) for k, v in sorted(buckets.items())}


def score_all(
    plans: Iterable[TradePlan],
    bars_by_symbol: Mapping[str, Sequence[Bar]],
    *,
    horizon: int = 20,
    slippage_bps: float = 0.0,
) -> Summary:
    outcomes = [
        score_trade(
            plan,
            bars_by_symbol.get(plan.symbol.upper(), []),
            horizon=horizon,
            slippage_bps=slippage_bps,
        )
        for plan in plans
    ]
    return Summary(outcomes)
