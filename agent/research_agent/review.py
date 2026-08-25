"""Read back a dry run.

A few days of scheduled passes leaves hundreds of decision objects and a long
diary. The question they exist to answer is narrow: *would I have been happy if
this had been live?* That means seeing every trade it wanted to place, and the
reasons it stood down, without scrolling.

    python -m research_agent.review logs/
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, Optional

# Group "RSI 78.4 is overbought" with "RSI 71.2 is overbought" by flattening
# the numbers out of a message before counting it.
# Must start with a digit: a bare comma is punctuation, not a number.
_NUMBER = re.compile(r"-?\d[\d,]*\.?\d*")


def normalise(message: str) -> str:
    return _NUMBER.sub("#", message).strip().rstrip(".")


@dataclass
class Pass:
    day: str
    mode: str = "unknown"


@dataclass
class Review:
    days: list[str] = field(default_factory=list)
    decisions: Counter = field(default_factory=Counter)
    trades: list[dict] = field(default_factory=list)
    vetoes: Counter = field(default_factory=Counter)
    adjustments: Counter = field(default_factory=Counter)
    stand_downs: Counter = field(default_factory=Counter)
    modes: Counter = field(default_factory=Counter)
    kill_switch_days: dict[str, str] = field(default_factory=dict)
    errors: list[str] = field(default_factory=list)
    submitted: list[str] = field(default_factory=list)
    passes: int = 0

    @property
    def total(self) -> int:
        return sum(self.decisions.values())


def _day_of(path: Path) -> str:
    stem = path.stem
    return stem.split("-", 1)[1] if "-" in stem else stem


def read_decisions(paths: Iterable[Path], review: Review) -> None:
    for path in sorted(paths):
        day = _day_of(path)
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except ValueError:
                review.errors.append(f"{path.name}: unparseable line")
                continue

            decision = record.get("decision", "?")
            review.decisions[decision] += 1
            if decision in {"BUY", "SELL"}:
                review.trades.append({**record, "day": day})
            else:
                reasoning = record.get("reasoning", "")
                # An override states its own reasons; those are counted from
                # the diary, which is structured. Everything else is the model
                # or the harness declining on its own.
                if not reasoning.startswith("Risk layer overrode"):
                    review.stand_downs[normalise(reasoning)] += 1


def read_diaries(paths: Iterable[Path], review: Review) -> None:
    for path in sorted(paths):
        day = _day_of(path)
        for line in path.read_text().splitlines():
            if "=== pass start" in line:
                review.passes += 1
                mode = line.split("[", 1)[-1].split("]", 1)[0] if "[" in line else "unknown"
                review.modes[mode] += 1
            elif "[guardrail] VETO:" in line:
                review.vetoes[normalise(line.split("VETO:", 1)[1])] += 1
            elif "[guardrail] adjusted:" in line:
                review.adjustments[normalise(line.split("adjusted:", 1)[1])] += 1
            elif "[kill-switch] HALTED" in line:
                review.kill_switch_days.setdefault(day, line.split(":", 3)[-1].strip())
            elif "[execution] SUBMITTED" in line:
                review.submitted.append(f"{day}: {line.split('SUBMITTED', 1)[1].strip()}")
            elif "[error]" in line or "exited" in line and "exited 0" not in line:
                review.errors.append(f"{day}: {line.strip()}")


def collect(log_dir: Path) -> Review:
    review = Review()
    decisions = list(log_dir.glob("decisions-*.jsonl"))
    diaries = list(log_dir.glob("agent-*.log"))
    review.days = sorted({_day_of(p) for p in decisions + diaries})
    read_decisions(decisions, review)
    read_diaries(diaries, review)
    return review


def _bar(count: int, total: int, width: int = 24) -> str:
    filled = 0 if total <= 0 else round(width * count / total)
    return "#" * filled + "." * (width - filled)


def render(review: Review, *, show_trades: int = 40) -> str:
    if not review.days:
        return "No logs found. Has the scheduler run yet?"

    span = review.days[0] if len(review.days) == 1 else f"{review.days[0]} to {review.days[-1]}"
    modes = ", ".join(f"{m.lower()} x{n}" for m, n in review.modes.most_common()) or "unknown"
    out = [
        "=" * 72,
        f"Dry run review - {span}",
        f"{len(review.days)} session(s), {review.passes} pass(es), {review.total} decision(s)",
        f"Mode: {modes}",
        "=" * 72,
        "",
        "DECISIONS",
    ]
    for decision, count in review.decisions.most_common():
        pct = count / review.total * 100 if review.total else 0
        out.append(f"  {decision:<10} {count:>5}  {pct:>5.1f}%  {_bar(count, review.total)}")

    out += ["", f"TRADES IT WANTED TO PLACE ({len(review.trades)})"]
    if not review.trades:
        out.append("  (none - it stood down every time)")
    else:
        for trade in review.trades[:show_trades]:
            qty = trade.get("qty")
            out.append(
                f"  {trade['day']}  {trade['decision']:<4} "
                f"{'' if qty is None else int(qty):>6} {trade.get('symbol', '?'):<6} "
                f"{trade.get('confidence', '?'):<6} {trade.get('reasoning', '')[:80]}"
            )
        if len(review.trades) > show_trades:
            out.append(f"  ... and {len(review.trades) - show_trades} more")

    if review.submitted:
        out += ["", f"ORDERS ACTUALLY SUBMITTED ({len(review.submitted)})"]
        out += [f"  {s[:100]}" for s in review.submitted[:show_trades]]

    if review.vetoes:
        out += ["", f"GUARDRAIL VETOES ({sum(review.vetoes.values())})"]
        for reason, count in review.vetoes.most_common():
            out.append(f"  {count:>5}  {reason[:88]}")

    if review.stand_downs:
        out += ["", f"STOOD DOWN ON ITS OWN ({sum(review.stand_downs.values())})"]
        for reason, count in review.stand_downs.most_common(12):
            out.append(f"  {count:>5}  {reason[:88]}")

    if review.adjustments:
        out += ["", f"SIZE ADJUSTMENTS ({sum(review.adjustments.values())})"]
        for note, count in review.adjustments.most_common(12):
            out.append(f"  {count:>5}  {note[:88]}")

    if review.kill_switch_days:
        out += ["", f"KILL-SWITCH DAYS ({len(review.kill_switch_days)})"]
        for day, detail in sorted(review.kill_switch_days.items()):
            out.append(f"  {day}  {detail[:80]}")

    out += ["", f"ERRORS ({len(review.errors)})"]
    out += [f"  {e[:100]}" for e in review.errors[:10]] or ["  (none)"]
    if len(review.errors) > 10:
        out.append(f"  ... and {len(review.errors) - 10} more")

    out += [
        "",
        "-" * 72,
        "Before switching EXECUTE on, satisfy yourself that you agree with every",
        "trade listed above, and that the vetoes fired for reasons you accept.",
    ]
    return "\n".join(out)


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        prog="research-agent-review",
        description="Summarise scheduled runs so a dry run can be judged.",
    )
    parser.add_argument("log_dir", nargs="?", default="logs", help="directory of run logs")
    parser.add_argument("--trades", type=int, default=40, help="how many trades to list")
    parser.add_argument("--json", action="store_true", help="emit the summary as JSON")
    args = parser.parse_args(argv)

    log_dir = Path(args.log_dir)
    if not log_dir.is_dir():
        print(f"no such log directory: {log_dir}", file=sys.stderr)
        return 1

    review = collect(log_dir)
    if args.json:
        print(json.dumps(
            {
                "days": review.days,
                "passes": review.passes,
                "decisions": dict(review.decisions),
                "trades": review.trades,
                "vetoes": dict(review.vetoes),
                "stand_downs": dict(review.stand_downs),
                "adjustments": dict(review.adjustments),
                "kill_switch_days": review.kill_switch_days,
                "errors": review.errors,
            },
            indent=2,
        ))
    else:
        print(render(review, show_trades=args.trades))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
