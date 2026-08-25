"""Thin HTTP layer over Alpaca's REST API.

Kept deliberately small: every endpoint used by this bot is listed here so the
surface we depend on is auditable in one screen.
"""

from __future__ import annotations

import logging
from typing import Any, Mapping

import requests

from .config import AlpacaSettings

log = logging.getLogger(__name__)


class AlpacaError(RuntimeError):
    """An Alpaca request failed. Carries status and body for diagnosis."""

    def __init__(self, method: str, url: str, status: int, body: str) -> None:
        super().__init__(f"{method} {url} -> HTTP {status}: {body[:500]}")
        self.status = status
        self.body = body


class AlpacaHTTP:
    def __init__(self, settings: AlpacaSettings, session: requests.Session | None = None) -> None:
        settings.require_credentials()
        self._settings = settings
        self._session = session or requests.Session()
        self._session.headers.update(
            {
                "APCA-API-KEY-ID": settings.key_id,
                "APCA-API-SECRET-KEY": settings.secret_key,
                "Accept": "application/json",
            }
        )

    @property
    def settings(self) -> AlpacaSettings:
        return self._settings

    def _request(
        self,
        method: str,
        base: str,
        path: str,
        *,
        params: Mapping[str, Any] | None = None,
        json_body: Mapping[str, Any] | None = None,
    ) -> Any:
        url = f"{base}{path}"
        log.debug("%s %s params=%s", method, url, params)
        try:
            resp = self._session.request(
                method,
                url,
                params=params,
                json=json_body,
                timeout=self._settings.timeout_seconds,
            )
        except requests.RequestException as exc:  # network-level failure
            raise AlpacaError(method, url, 0, str(exc)) from exc

        if resp.status_code >= 400:
            raise AlpacaError(method, url, resp.status_code, resp.text)
        if not resp.content:
            return None
        return resp.json()

    # --- market data plane ---------------------------------------------------
    def data_get(self, path: str, params: Mapping[str, Any] | None = None) -> Any:
        return self._request("GET", self._settings.data_base_url, path, params=params)

    # --- trading plane -------------------------------------------------------
    def trading_get(self, path: str, params: Mapping[str, Any] | None = None) -> Any:
        return self._request("GET", self._settings.trading_base_url, path, params=params)

    def trading_post(self, path: str, json_body: Mapping[str, Any]) -> Any:
        return self._request(
            "POST", self._settings.trading_base_url, path, json_body=json_body
        )
