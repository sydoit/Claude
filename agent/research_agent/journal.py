"""A richer record of each decision, written alongside the spec's JSON.

The decision object is exactly five fields, which is the contract and stays
that way. But those five fields cannot be scored later: they say `BUY 131 NVDA`
without saying at what price, with what stop, or against what target. Replaying
a decision needs the numbers that produced it, so they are journalled here.

One JSON object per line, appended. Nothing reads this at trade time - it
exists purely so `scoring` has something honest to replay.
"""

from __future__ import annotations

import json
import logging
from pathlib import Path
from typing import Optional

from .execution import ExecutionReport
from .guardrails import GuardrailResult
from .research import ResearchBrief

log = logging.getLogger(__name__)


def build_record(
    brief: ResearchBrief,
    result: GuardrailResult,
    *,
    proposed_qty: Optional[float] = None,
    proposed_confidence: Optional[str] = None,
    report: Optional[ExecutionReport] = None,
) -> dict:
    decision = result.decision
    plan = result.plan
    record: dict = {
        "ts": brief.generated_at.isoformat(),
        "trading_day": brief.session.now_et.date().isoformat(),
        "symbol": brief.symbol,
        "timeframe": brief.timeframe,
        "decision": decision.decision,
        "qty": decision.qty,
        "confidence": decision.confidence,
        "reasoning": decision.reasoning,
        "proposed_qty": proposed_qty,
        "proposed_confidence": proposed_confidence,
        "reference_price": brief.reference_price,
        "rsi": brief.rsi,
        "atr": brief.atr,
        "portfolio_value": brief.portfolio_value,
        "vetoes": list(result.vetoes),
        "adjustments": list(result.adjustments),
        "executed": bool(report and report.submitted),
        "execution": None if report is None else report.action,
    }
    if plan is not None:
        record.update(
            entry=plan.entry_price,
            stop=plan.stop_price,
            target=plan.take_profit_price,
            stop_distance=plan.stop_distance,
            risk=plan.risk_for(decision.qty or 0),
        )
    return record


def append(path: str | Path, record: dict) -> None:
    """Append one record. A journal that cannot be written must not stop a run."""
    try:
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "a") as fh:
            fh.write(json.dumps(record, default=str) + "\n")
    except OSError as exc:
        log.warning("could not write journal to %s: %s", path, exc)


def read(path: str | Path) -> list[dict]:
    records: list[dict] = []
    try:
        text = Path(path).read_text()
    except OSError:
        return records
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except ValueError:
            log.warning("skipping unparseable journal line in %s", path)
    return records
