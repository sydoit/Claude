#!/usr/bin/env bash
#
# One scheduled pass over the watchlist. Safe to point cron or a systemd timer
# at this: it holds a lock, keeps its own working directory, and appends every
# decision to a per-day audit log.
#
#   SYMBOLS="NVDA AAPL" EXECUTE=1 scripts/run-once.sh
#
# Without EXECUTE=1 it is a dry run: it researches, decides, sizes, and logs,
# but submits nothing.

set -uo pipefail

AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$AGENT_DIR" || exit 1

SYMBOLS="${SYMBOLS:-NVDA}"
PYTHON="${PYTHON:-python3}"
LOG_DIR="${LOG_DIR:-$AGENT_DIR/logs}"
LOG_KEEP_DAYS="${LOG_KEEP_DAYS:-90}"

mkdir -p "$LOG_DIR"
DAY="$(TZ=America/New_York date +%F)"
DECISIONS="$LOG_DIR/decisions-$DAY.jsonl"
JOURNAL="$LOG_DIR/journal-$DAY.jsonl"
DIARY="$LOG_DIR/agent-$DAY.log"

# The kill-switch latch and .env both live beside this script, so a scheduler
# that starts elsewhere must not be allowed to lose them.
if [ ! -f "$AGENT_DIR/.env" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo "$(date -Is) no .env and no ANTHROPIC_API_KEY in the environment" >> "$DIARY"
    exit 78  # EX_CONFIG
fi

# One pass at a time. A slow run must never overlap the next tick.
exec 9>"$AGENT_DIR/.run.lock"
if ! flock -n 9; then
    echo "$(date -Is) previous run still going, skipping this tick" >> "$DIARY"
    exit 0
fi

EXECUTE_FLAG=()
MODE="DRY RUN"
if [ -n "${EXECUTE:-}" ]; then
    EXECUTE_FLAG=(--execute)
    MODE="EXECUTING"
fi

# A decision object looks the same whether or not it was acted on, so the mode
# has to be recorded here or the audit trail cannot tell you which it was.
echo "$(date -Is) === pass start [$MODE] symbols: $SYMBOLS ===" >> "$DIARY"

status=0
for symbol in $SYMBOLS; do
    echo "$(date -Is) --- $symbol ---" >> "$DIARY"
    "$PYTHON" -m research_agent "$symbol" --compact --journal "$JOURNAL" \
        "${EXECUTE_FLAG[@]}" \
        >> "$DECISIONS" 2>> "$DIARY"
    rc=$?
    # 0 = decided (trade or no-trade). Anything else is worth noticing, but one
    # bad symbol must not stop the rest of the watchlist.
    [ $rc -ne 0 ] && { echo "$(date -Is) $symbol exited $rc" >> "$DIARY"; status=$rc; }
done

find "$LOG_DIR" -name '*.log' -o -name '*.jsonl' -type f -mtime "+$LOG_KEEP_DAYS" -delete 2>/dev/null
exit $status
