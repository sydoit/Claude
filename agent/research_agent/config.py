"""Runtime policy. Every risk rule lives here as a number, not as prose."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from datetime import time
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


def _market_tz() -> ZoneInfo:
    """The exchange timezone.

    Linux and macOS ship a system tz database; Windows does not, so there the
    `tzdata` package supplies it. Without a timezone this agent cannot tell
    whether the market is open, so failing clearly beats failing obscurely.
    """
    try:
        return ZoneInfo("America/New_York")
    except ZoneInfoNotFoundError as exc:  # pragma: no cover - platform specific
        raise RuntimeError(
            "No timezone database found, so market hours cannot be determined. "
            "On Windows this is expected: install the tzdata package with\n"
            "    py -m pip install tzdata\n"
            "(it is already listed in requirements.txt for Windows)."
        ) from exc


MARKET_TZ = _market_tz()

PAPER_HOSTS = ("paper-api.alpaca.markets",)


def _env_bool(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "y", "on"}


def _env_float(name: str, default: float) -> float:
    raw = os.getenv(name)
    if raw is None or not raw.strip():
        return default
    return float(raw)


def _env_int(name: str, default: int) -> int:
    raw = os.getenv(name)
    if raw is None or not raw.strip():
        return default
    return int(raw)


class ConfigError(ValueError):
    """Raised when the configured policy is internally inconsistent."""


@dataclass(frozen=True)
class RiskPolicy:
    """The hard limits. These are enforced in code; the prompt only echoes them."""

    max_risk_pct: float = 0.02
    max_portfolio_risk_pct: float = 0.06
    max_cluster_risk_pct: float = 0.04
    correlation_threshold: float = 0.7
    correlation_lookback: int = 60
    correlation_min_observations: int = 20
    max_daily_drawdown_pct: float = 0.03
    kill_switch_latch: bool = True
    max_position_pct: float = 0.25
    stop_atr_mult: float = 1.5
    take_profit_r: float = 2.0
    rsi_period: int = 14
    rsi_overbought: float = 70.0
    rsi_oversold: float = 30.0
    atr_period: int = 14
    allow_contrarian_override: bool = True
    min_confidence: str = "MEDIUM"
    session_open: time = time(9, 30)
    session_close: time = time(16, 0)
    # Refuse to act on a decision derived from a quote older than this.
    max_quote_age_seconds: int = 120

    def __post_init__(self) -> None:
        if not 0 < self.max_risk_pct <= 0.02:
            raise ConfigError(
                f"max_risk_pct must be in (0, 0.02]; the spec caps single-trade "
                f"risk at 2% of portfolio value, got {self.max_risk_pct!r}"
            )
        if not 0 < self.max_portfolio_risk_pct <= 1:
            raise ConfigError(
                "max_portfolio_risk_pct must be in (0, 1], got "
                f"{self.max_portfolio_risk_pct!r}"
            )
        if self.max_portfolio_risk_pct < self.max_risk_pct:
            raise ConfigError(
                f"max_portfolio_risk_pct ({self.max_portfolio_risk_pct:.2%}) is "
                f"below max_risk_pct ({self.max_risk_pct:.2%}), which would make "
                "even a single full-size trade impossible"
            )
        if not self.max_risk_pct <= self.max_cluster_risk_pct <= self.max_portfolio_risk_pct:
            raise ConfigError(
                f"require max_risk_pct ({self.max_risk_pct:.2%}) <= "
                f"max_cluster_risk_pct ({self.max_cluster_risk_pct:.2%}) <= "
                f"max_portfolio_risk_pct ({self.max_portfolio_risk_pct:.2%})"
            )
        if not 0 < self.max_daily_drawdown_pct <= 1:
            raise ConfigError(
                "max_daily_drawdown_pct must be in (0, 1], got "
                f"{self.max_daily_drawdown_pct!r}"
            )
        if self.max_daily_drawdown_pct < self.max_risk_pct:
            raise ConfigError(
                f"max_daily_drawdown_pct ({self.max_daily_drawdown_pct:.2%}) is "
                f"below max_risk_pct ({self.max_risk_pct:.2%}): a single losing "
                "trade would end every session before a second could be placed"
            )
        if not 0 < self.correlation_threshold <= 1:
            raise ConfigError("correlation_threshold must be in (0, 1]")
        if self.correlation_lookback < 5 or self.correlation_min_observations < 2:
            raise ConfigError(
                "correlation_lookback must be >= 5 and "
                "correlation_min_observations >= 2"
            )
        if self.correlation_min_observations > self.correlation_lookback:
            raise ConfigError(
                "correlation_min_observations cannot exceed correlation_lookback"
            )
        if not 0 < self.max_position_pct <= 1:
            raise ConfigError("max_position_pct must be in (0, 1]")
        if self.stop_atr_mult <= 0:
            raise ConfigError("stop_atr_mult must be positive")
        if not 0 < self.rsi_oversold < self.rsi_overbought < 100:
            raise ConfigError("require 0 < rsi_oversold < rsi_overbought < 100")
        if self.rsi_period < 2 or self.atr_period < 2:
            raise ConfigError("indicator periods must be >= 2")
        if self.min_confidence not in {"LOW", "MEDIUM", "HIGH"}:
            raise ConfigError("min_confidence must be LOW, MEDIUM or HIGH")
        if self.session_open >= self.session_close:
            raise ConfigError("session_open must precede session_close")

    @classmethod
    def from_env(cls) -> "RiskPolicy":
        return cls(
            max_risk_pct=_env_float("MAX_RISK_PCT", 0.02),
            max_portfolio_risk_pct=_env_float("MAX_PORTFOLIO_RISK_PCT", 0.06),
            max_cluster_risk_pct=_env_float("MAX_CLUSTER_RISK_PCT", 0.04),
            correlation_threshold=_env_float("CORRELATION_THRESHOLD", 0.7),
            correlation_lookback=_env_int("CORRELATION_LOOKBACK", 60),
            correlation_min_observations=_env_int("CORRELATION_MIN_OBSERVATIONS", 20),
            max_daily_drawdown_pct=_env_float("MAX_DAILY_DRAWDOWN_PCT", 0.03),
            kill_switch_latch=_env_bool("KILL_SWITCH_LATCH", True),
            max_position_pct=_env_float("MAX_POSITION_PCT", 0.25),
            stop_atr_mult=_env_float("STOP_ATR_MULT", 1.5),
            take_profit_r=_env_float("TAKE_PROFIT_R", 2.0),
            rsi_period=_env_int("RSI_PERIOD", 14),
            rsi_overbought=_env_float("RSI_OVERBOUGHT", 70.0),
            rsi_oversold=_env_float("RSI_OVERSOLD", 30.0),
            atr_period=_env_int("ATR_PERIOD", 14),
            allow_contrarian_override=_env_bool("ALLOW_CONTRARIAN_OVERRIDE", True),
            min_confidence=os.getenv("MIN_CONFIDENCE", "MEDIUM").strip().upper() or "MEDIUM",
            max_quote_age_seconds=_env_int("MAX_QUOTE_AGE_SECONDS", 120),
        )


@dataclass(frozen=True)
class AlpacaSettings:
    key_id: str = ""
    secret_key: str = ""
    data_base_url: str = "https://data.alpaca.markets"
    trading_base_url: str = "https://paper-api.alpaca.markets"
    feed: str = "iex"
    timeout_seconds: float = 15.0

    @property
    def is_paper(self) -> bool:
        from urllib.parse import urlparse

        return (urlparse(self.trading_base_url).hostname or "") in PAPER_HOSTS

    def require_credentials(self) -> None:
        if not self.key_id or not self.secret_key:
            raise ConfigError(
                "APCA_API_KEY_ID and APCA_API_SECRET_KEY must be set. "
                "Copy .env.example to .env and fill them in."
            )

    @classmethod
    def from_env(cls) -> "AlpacaSettings":
        return cls(
            key_id=os.getenv("APCA_API_KEY_ID", "").strip(),
            secret_key=os.getenv("APCA_API_SECRET_KEY", "").strip(),
            data_base_url=os.getenv("ALPACA_DATA_BASE_URL", "https://data.alpaca.markets").rstrip("/"),
            trading_base_url=os.getenv(
                "ALPACA_TRADING_BASE_URL", "https://paper-api.alpaca.markets"
            ).rstrip("/"),
            feed=os.getenv("ALPACA_DATA_FEED", "iex").strip().lower(),
            timeout_seconds=_env_float("ALPACA_TIMEOUT_SECONDS", 15.0),
        )


@dataclass(frozen=True)
class AgentSettings:
    model: str = "claude-opus-5"
    effort: str = "high"
    max_tokens: int = 8000
    risk: RiskPolicy = field(default_factory=RiskPolicy)
    alpaca: AlpacaSettings = field(default_factory=AlpacaSettings)
    # Never submit an order to a non-paper endpoint unless this is explicitly on.
    allow_live_trading: bool = False

    @classmethod
    def from_env(cls) -> "AgentSettings":
        return cls(
            model=os.getenv("AGENT_MODEL", "claude-opus-5").strip() or "claude-opus-5",
            effort=os.getenv("AGENT_EFFORT", "high").strip() or "high",
            max_tokens=_env_int("AGENT_MAX_TOKENS", 8000),
            risk=RiskPolicy.from_env(),
            alpaca=AlpacaSettings.from_env(),
            allow_live_trading=_env_bool("ALLOW_LIVE_TRADING", False),
        )
