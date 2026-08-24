"""Assemble the market research brief that Claude reasons over."""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Optional, Sequence

from .broker import Account, MarketClock, Position
from .config import MARKET_TZ, RiskPolicy
from .indicators import Bar, InsufficientData, atr, pct_change, rsi, sma
from .market_data import Headline, MarketDataProvider, Quote


@dataclass(frozen=True)
class SessionState:
    """Is the market open, per the spec's 9:30-16:00 ET rule and per the broker?"""

    now_et: datetime
    within_spec_window: bool
    broker_says_open: Optional[bool]
    detail: str

    @property
    def is_tradeable(self) -> bool:
        if not self.within_spec_window:
            return False
        # An explicit "closed" from the broker outranks the clock: it knows about
        # holidays and half-days that a naive time window does not.
        return self.broker_says_open is not False


def evaluate_session(
    policy: RiskPolicy,
    *,
    now: Optional[datetime] = None,
    clock: Optional[MarketClock] = None,
) -> SessionState:
    now = now or datetime.now(timezone.utc)
    now_et = now.astimezone(MARKET_TZ)
    is_weekday = now_et.weekday() < 5
    in_window = policy.session_open <= now_et.time() < policy.session_close
    within = is_weekday and in_window

    bits = [f"{now_et:%Y-%m-%d %H:%M:%S %Z} (ET)"]
    if not is_weekday:
        bits.append("weekend")
    elif not in_window:
        bits.append(
            f"outside {policy.session_open:%H:%M}-{policy.session_close:%H:%M} ET"
        )
    else:
        bits.append("inside regular hours")
    broker_open = None
    if clock is not None:
        broker_open = clock.is_open
        bits.append(f"broker reports market {'open' if clock.is_open else 'closed'}")

    return SessionState(
        now_et=now_et,
        within_spec_window=within,
        broker_says_open=broker_open,
        detail="; ".join(bits),
    )


@dataclass(frozen=True)
class ResearchBrief:
    symbol: str
    generated_at: datetime
    timeframe: str
    quote: Quote
    last_close: float
    rsi: float
    atr: float
    sma20: Optional[float]
    sma50: Optional[float]
    change_1d: Optional[float]
    change_5d: Optional[float]
    change_20d: Optional[float]
    avg_volume_20: Optional[float]
    last_volume: float
    bar_count: int
    session: SessionState
    portfolio_value: float
    buying_power: float
    open_position: Optional[Position]
    headlines: Sequence[Headline] = field(default_factory=tuple)
    warnings: Sequence[str] = field(default_factory=tuple)

    @property
    def reference_price(self) -> float:
        """Price used for sizing: the live mid, falling back to the last close."""
        return self.quote.mid or self.last_close

    def rsi_zone(self, policy: RiskPolicy) -> str:
        if self.rsi >= policy.rsi_overbought:
            return "OVERBOUGHT"
        if self.rsi <= policy.rsi_oversold:
            return "OVERSOLD"
        return "NEUTRAL"

    def to_prompt_block(self, policy: RiskPolicy) -> str:
        def num(v: Optional[float], suffix: str = "", places: int = 2) -> str:
            return "unavailable" if v is None else f"{v:,.{places}f}{suffix}"

        pos = self.open_position
        pos_line = (
            "flat (no open position)"
            if pos is None or pos.qty == 0
            else (
                f"{'LONG' if pos.is_long else 'SHORT'} {abs(pos.qty):g} shares "
                f"@ avg {pos.avg_entry_price:,.2f} (market value {pos.market_value:,.2f})"
            )
        )
        lines = [
            f"SYMBOL: {self.symbol}",
            f"AS OF: {self.generated_at:%Y-%m-%d %H:%M:%S %Z}",
            "",
            "SESSION",
            f"  Clock: {self.session.detail}",
            f"  Tradeable under the 9:30-16:00 ET rule: "
            f"{'YES' if self.session.is_tradeable else 'NO'}",
            "",
            f"PRICE ({self.timeframe} bars, {self.bar_count} of them)",
            f"  Bid/ask: {self.quote.bid:,.2f} / {self.quote.ask:,.2f}"
            f"  (mid {self.quote.mid:,.2f}, spread {self.quote.spread:,.4f},"
            f" quote age {self.quote.age_seconds():.0f}s)",
            f"  Last close: {num(self.last_close)}",
            f"  Change 1d / 5d / 20d: {num(self.change_1d, '%')} /"
            f" {num(self.change_5d, '%')} / {num(self.change_20d, '%')}",
            f"  SMA20 / SMA50: {num(self.sma20)} / {num(self.sma50)}",
            f"  Volume last / 20d avg: {num(self.last_volume, places=0)} /"
            f" {num(self.avg_volume_20, places=0)}",
            "",
            "INDICATORS",
            f"  RSI({policy.rsi_period}): {self.rsi:.2f}  ->"
            f" {self.rsi_zone(policy)}"
            f"  (overbought >= {policy.rsi_overbought:g},"
            f" oversold <= {policy.rsi_oversold:g})",
            f"  ATR({policy.atr_period}): {self.atr:,.4f}"
            f"  -> stop distance {policy.stop_atr_mult:g} x ATR ="
            f" {policy.stop_atr_mult * self.atr:,.4f}",
            "",
            "ACCOUNT",
            f"  Portfolio value: {self.portfolio_value:,.2f}",
            f"  Buying power: {self.buying_power:,.2f}",
            f"  Current exposure in {self.symbol}: {pos_line}",
            f"  Risk budget for this trade ({policy.max_risk_pct:.2%} of portfolio):"
            f" {self.portfolio_value * policy.max_risk_pct:,.2f}",
        ]
        if self.headlines:
            lines += ["", "RECENT HEADLINES"]
            lines += [
                f"  - [{h.ts:%Y-%m-%d %H:%M}] {h.headline} ({h.source})"
                for h in self.headlines
            ]
        if self.warnings:
            lines += ["", "DATA WARNINGS"]
            lines += [f"  - {w}" for w in self.warnings]
        return "\n".join(lines)


def build_brief(
    symbol: str,
    *,
    provider: MarketDataProvider,
    policy: RiskPolicy,
    account: Account,
    position: Optional[Position],
    clock: Optional[MarketClock],
    timeframe: str = "1Day",
    bar_limit: int = 120,
    news_limit: int = 6,
    now: Optional[datetime] = None,
) -> ResearchBrief:
    symbol = symbol.strip().upper()
    warnings: list[str] = []

    bars: list[Bar] = provider.bars(symbol, timeframe=timeframe, limit=bar_limit)
    needed = max(policy.rsi_period, policy.atr_period) + 1
    if len(bars) < needed:
        raise InsufficientData(
            f"{symbol}: need at least {needed} {timeframe} bars to compute "
            f"RSI({policy.rsi_period})/ATR({policy.atr_period}), got {len(bars)}"
        )

    quote = provider.latest_quote(symbol)
    age = quote.age_seconds(now)
    if age > policy.max_quote_age_seconds:
        warnings.append(
            f"latest quote is {age:.0f}s old (limit {policy.max_quote_age_seconds}s)"
        )

    def maybe(fn, *args, **kwargs):
        try:
            return fn(*args, **kwargs)
        except InsufficientData:
            return None

    return ResearchBrief(
        symbol=symbol,
        generated_at=(now or datetime.now(timezone.utc)),
        timeframe=timeframe,
        quote=quote,
        last_close=bars[-1].close,
        rsi=rsi(bars, policy.rsi_period),
        atr=atr(bars, policy.atr_period),
        sma20=maybe(sma, bars, 20),
        sma50=maybe(sma, bars, 50),
        change_1d=maybe(pct_change, bars, 1),
        change_5d=maybe(pct_change, bars, 5),
        change_20d=maybe(pct_change, bars, 20),
        avg_volume_20=(
            sum(b.volume for b in bars[-20:]) / 20 if len(bars) >= 20 else None
        ),
        last_volume=bars[-1].volume,
        bar_count=len(bars),
        session=evaluate_session(policy, now=now, clock=clock),
        portfolio_value=account.portfolio_value,
        buying_power=account.buying_power,
        open_position=position,
        headlines=tuple(provider.news(symbol, limit=news_limit)),
        warnings=tuple(warnings),
    )
