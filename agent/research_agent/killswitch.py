"""Daily drawdown kill-switch.

The risk caps size entries. None of them stops a bad day from compounding: you
can lose the per-trade limit, take another trade, lose again, and stay inside
every cap on the way down. This halts new entries once the day's loss crosses a
threshold.

Two properties matter.

**The baseline needs no local state.** Today's loss is measured against the
broker's own `last_equity` - equity at the prior close - so the measurement is
correct after a restart, on a fresh machine, and for losses taken by hand.

**The switch latches.** Once tripped it stays tripped for the rest of the
trading day, even if equity recovers. A switch that un-trips the moment the
screen turns green is not a circuit breaker, it is a way to get whipsawed back
into the position that just hurt you. Latching is the one thing here that does
need to be remembered, so it is written to a small file keyed by trading date.

Exits are never blocked. The point is to stop opening risk, not to trap the
account in what it already holds.
"""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Optional, Protocol

from .broker import Account
from .config import MARKET_TZ, RiskPolicy

log = logging.getLogger(__name__)

DEFAULT_LATCH_FILE = ".killswitch.json"


def trading_day(now: Optional[datetime] = None) -> date:
    """The ET calendar date a session belongs to."""
    now = now or datetime.now(timezone.utc)
    return now.astimezone(MARKET_TZ).date()


@dataclass(frozen=True)
class DrawdownState:
    trading_day: date
    start_equity: float
    current_equity: float
    pnl: float
    pnl_pct: float
    limit_pct: float
    tripped: bool
    latched: bool
    measurable: bool
    detail: str

    @property
    def halts_entries(self) -> bool:
        return self.tripped

    def describe(self) -> str:
        if not self.measurable:
            return f"daily drawdown unmeasurable: {self.detail}"
        headroom = max(
            self.start_equity * self.limit_pct + self.pnl, 0.0
        )
        base = (
            f"day P&L {self.pnl:+,.2f} ({self.pnl_pct:+.2%}) against a "
            f"{self.limit_pct:.2%} limit"
        )
        if self.tripped:
            return f"KILL SWITCH TRIPPED - {base}{' (latched earlier today)' if self.latched else ''}"
        return f"{base}; {headroom:,.2f} of daily loss budget left"


class LatchStore(Protocol):
    def read(self) -> Optional[dict]: ...
    def write(self, payload: dict) -> None: ...
    def clear(self) -> None: ...


class FileLatchStore:
    """Records that the switch tripped, keyed by trading date."""

    def __init__(self, path: str | Path = DEFAULT_LATCH_FILE) -> None:
        self.path = Path(path)

    def read(self) -> Optional[dict]:
        try:
            return json.loads(self.path.read_text())
        except (OSError, ValueError):
            return None

    def write(self, payload: dict) -> None:
        try:
            self.path.write_text(json.dumps(payload, indent=2, default=str))
        except OSError as exc:
            # A latch we cannot persist still halts this run; say so rather
            # than pretending the switch is armed for the next one.
            log.warning("could not persist kill-switch latch to %s: %s", self.path, exc)

    def clear(self) -> None:
        try:
            self.path.unlink()
        except OSError:
            pass


class NullLatchStore:
    """No persistence: the switch is evaluated fresh every run."""

    def read(self) -> Optional[dict]:
        return None

    def write(self, payload: dict) -> None:
        return None

    def clear(self) -> None:
        return None


def evaluate(
    account: Account,
    policy: RiskPolicy,
    *,
    now: Optional[datetime] = None,
    store: Optional[LatchStore] = None,
) -> DrawdownState:
    """Measure today's drawdown and decide whether entries are halted."""
    store = store if store is not None else NullLatchStore()
    today = trading_day(now)
    baseline = account.last_equity
    equity = account.equity

    latched = False
    if policy.kill_switch_latch:
        record = store.read()
        if record and str(record.get("trading_day")) == today.isoformat():
            latched = True

    if baseline <= 0:
        # No baseline means no measurable floor under the day. Consistent with
        # the rest of the risk layer, an unmeasurable limit is a breached one.
        return DrawdownState(
            trading_day=today,
            start_equity=baseline,
            current_equity=equity,
            pnl=0.0,
            pnl_pct=0.0,
            limit_pct=policy.max_daily_drawdown_pct,
            tripped=True,
            latched=latched,
            measurable=False,
            detail=(
                "the broker reported no prior-close equity, so today's loss "
                "cannot be measured"
            ),
        )

    pnl = equity - baseline
    pnl_pct = pnl / baseline
    breached = pnl_pct <= -policy.max_daily_drawdown_pct

    if breached and not latched and policy.kill_switch_latch:
        store.write(
            {
                "trading_day": today.isoformat(),
                "tripped_at": (now or datetime.now(timezone.utc)).isoformat(),
                "pnl": pnl,
                "pnl_pct": pnl_pct,
                "limit_pct": policy.max_daily_drawdown_pct,
                "start_equity": baseline,
                "equity_at_trip": equity,
            }
        )

    return DrawdownState(
        trading_day=today,
        start_equity=baseline,
        current_equity=equity,
        pnl=pnl,
        pnl_pct=pnl_pct,
        limit_pct=policy.max_daily_drawdown_pct,
        tripped=breached or latched,
        latched=latched,
        measurable=True,
        detail=(
            f"equity {equity:,.2f} against a prior close of {baseline:,.2f}"
        ),
    )
