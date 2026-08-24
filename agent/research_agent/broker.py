"""The trading plane: account state, market clock, and order submission.

Nothing here decides *whether* to trade — it only carries out a decision that
has already cleared `guardrails`. The one judgement it does make is refusing to
talk to a live-money endpoint unless that was explicitly, separately enabled.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import datetime
from typing import Any, Optional

from .alpaca_client import AlpacaError, AlpacaHTTP
from .config import AgentSettings
from .market_data import _parse_ts

log = logging.getLogger(__name__)


class LiveTradingBlocked(RuntimeError):
    """Refused to submit an order to a non-paper endpoint."""


@dataclass(frozen=True)
class MarketClock:
    timestamp: datetime
    is_open: bool
    next_open: Optional[datetime]
    next_close: Optional[datetime]


@dataclass(frozen=True)
class Account:
    account_number: str
    portfolio_value: float
    buying_power: float
    cash: float
    equity: float
    trading_blocked: bool
    pattern_day_trader: bool


@dataclass(frozen=True)
class Position:
    symbol: str
    qty: float  # signed: negative means short
    avg_entry_price: float
    market_value: float

    @property
    def is_long(self) -> bool:
        return self.qty > 0

    @property
    def is_short(self) -> bool:
        return self.qty < 0


@dataclass(frozen=True)
class OrderResult:
    id: str
    client_order_id: str
    symbol: str
    side: str
    qty: float
    order_class: str
    status: str
    submitted_at: Optional[datetime]
    raw: dict[str, Any]


class AlpacaBroker:
    def __init__(self, http: AlpacaHTTP, settings: AgentSettings) -> None:
        self._http = http
        self._settings = settings

    # --- read -----------------------------------------------------------------
    def clock(self) -> MarketClock:
        p = self._http.trading_get("/v2/clock") or {}
        return MarketClock(
            timestamp=_parse_ts(p["timestamp"]),
            is_open=bool(p.get("is_open")),
            next_open=_parse_ts(p["next_open"]) if p.get("next_open") else None,
            next_close=_parse_ts(p["next_close"]) if p.get("next_close") else None,
        )

    def account(self) -> Account:
        p = self._http.trading_get("/v2/account") or {}
        return Account(
            account_number=str(p.get("account_number", "")),
            portfolio_value=float(p.get("portfolio_value", 0) or 0),
            buying_power=float(p.get("buying_power", 0) or 0),
            cash=float(p.get("cash", 0) or 0),
            equity=float(p.get("equity", 0) or 0),
            trading_blocked=bool(p.get("trading_blocked")),
            pattern_day_trader=bool(p.get("pattern_day_trader")),
        )

    def position(self, symbol: str) -> Optional[Position]:
        try:
            p = self._http.trading_get(f"/v2/positions/{symbol}") or {}
        except AlpacaError as exc:
            if exc.status == 404:  # no open position — the normal case
                return None
            raise
        return Position(
            symbol=p.get("symbol", symbol),
            qty=float(p.get("qty", 0) or 0),
            avg_entry_price=float(p.get("avg_entry_price", 0) or 0),
            market_value=float(p.get("market_value", 0) or 0),
        )

    # --- write ----------------------------------------------------------------
    def _assert_paper(self) -> None:
        if self._settings.alpaca.is_paper:
            return
        if not self._settings.allow_live_trading:
            raise LiveTradingBlocked(
                "Refusing to submit an order: ALPACA_TRADING_BASE_URL points at "
                f"{self._settings.alpaca.trading_base_url!r}, which is not a paper "
                "endpoint. Set ALLOW_LIVE_TRADING=true only if you intend to trade "
                "real money."
            )
        log.warning("LIVE TRADING ENABLED — orders will use real money.")

    def submit_bracket_order(
        self,
        *,
        symbol: str,
        qty: float,
        side: str,
        stop_price: float,
        take_profit_price: float,
        client_order_id: str,
        time_in_force: str = "day",
    ) -> OrderResult:
        """Open a position with its protective stop attached in the same request.

        The stop is what makes the 2% risk cap real: the sizing math assumes we
        exit at `stop_price`, so the order is only honest if that stop exists
        from the moment the fill happens.
        """
        self._assert_paper()
        body = {
            "symbol": symbol,
            "qty": str(_whole(qty)),
            "side": side,
            "type": "market",
            "time_in_force": time_in_force,
            "order_class": "bracket",
            "take_profit": {"limit_price": f"{take_profit_price:.2f}"},
            "stop_loss": {"stop_price": f"{stop_price:.2f}"},
            "client_order_id": client_order_id,
        }
        return _order_result(self._http.trading_post("/v2/orders", body))

    def submit_closing_order(
        self, *, symbol: str, qty: float, side: str, client_order_id: str
    ) -> OrderResult:
        """Reduce or flatten an existing position. No bracket: risk is coming off."""
        self._assert_paper()
        body = {
            "symbol": symbol,
            "qty": str(_whole(qty)),
            "side": side,
            "type": "market",
            "time_in_force": "day",
            "reduce_only": True,
            "client_order_id": client_order_id,
        }
        return _order_result(self._http.trading_post("/v2/orders", body))


def _whole(qty: float) -> int:
    return int(qty)


def _order_result(p: Any) -> OrderResult:
    p = p or {}
    return OrderResult(
        id=str(p.get("id", "")),
        client_order_id=str(p.get("client_order_id", "")),
        symbol=str(p.get("symbol", "")),
        side=str(p.get("side", "")),
        qty=float(p.get("qty", 0) or 0),
        order_class=str(p.get("order_class", "")),
        status=str(p.get("status", "")),
        submitted_at=_parse_ts(p["submitted_at"]) if p.get("submitted_at") else None,
        raw=dict(p),
    )
