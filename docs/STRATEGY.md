# Strategy reference

Everything the EA decides, in the order it decides it. Rule names in
parentheses are the inputs that control them.

## 1. Is the market trending?

Two layers must agree before any trigger is even considered.

**Higher-timeframe bias** (`InpTrendTF`, `InpHtfEmaFast`, `InpHtfEmaSlow`,
`InpUseHtfFilter`)
On the last closed bar of the trend timeframe, the fast EMA must sit clearly
above the slow EMA for a bullish bias, or clearly below for a bearish one.
"Clearly" means at least two points apart, so a flat crossover reads as *no
bias* rather than flapping between the two. With `InpUseHtfFilter = false` this
layer is skipped entirely.

**Entry-timeframe trend** (`InpEmaFast`, `InpEmaSlow`, `InpEmaSlopeLookback`)
On the entry timeframe, the fast EMA must be on the correct side of the slow
EMA **and** sloping the same way — the fast EMA now versus
`InpEmaSlopeLookback` bars ago. The stack alone is not enough; a stack with a
flat slope is exactly what a range looks like.

**Strength gate** (`InpAdxMin`)
ADX on the entry timeframe must be at or above `InpAdxMin`. This is the single
most effective filter in the whole system: without it the EA trades every
range-bound minute and pays the spread each time.

**Exhaustion veto** (`InpRsiBuyMin/Max`, `InpRsiSellMin/Max`)
RSI must be inside the band for that direction. The default long band is
45–78: below 45 the "uptrend" is not being confirmed by momentum, above 78 the
move is stretched and a pullback is more likely than a continuation.

Every reading above comes from bar index 1 — the last *closed* bar — so the
trend assessment never repaints inside the forming bar.

## 2. Trigger

Only when all of the above agree does the EA look for a way in. Both triggers
are checked against the **live** bid/ask, so an entry can happen mid-bar.

**Pullback that resumes** (`InpPullbackDepthAtr`)
For a long: the last closed bar dipped to within `InpPullbackDepthAtr × ATR` of
the fast EMA, still closed above it, and closed green — then the ask trades
through that bar's high. This buys the resumption of a trend after a dip, which
is where the stop can sit closest.

**Micro-breakout** (`InpBreakoutLookback`, `InpBreakoutBufferAtr`)
For a long: the ask trades above the highest high of the last
`InpBreakoutLookback` closed bars, plus a small ATR buffer to avoid paying for
noise at the exact high.

`InpEntryMode` selects one, the other, or whichever fires first. Shorts are the
exact mirror.

## 3. Size

(`InpLotMode`, `InpRiskPercent`, `InpMaxLots`, `InpMaxTotalLots`)

1. Stop price is computed first: `entry ∓ InpStopLossAtr × ATR`, then widened
   if the broker's minimum stop distance requires it.
2. The loss that stop implies for one lot is priced with `OrderCalcProfit`,
   which uses the broker's own contract size and currency conversion.
3. `volume = (equity × InpRiskPercent / 100) / loss-per-lot`.
4. The result is capped by `InpMaxLots`, then by the remaining headroom under
   `InpMaxTotalLots`, then rounded **down** to the broker's volume step.
5. If that is below the symbol minimum, or the margin check fails, the trade is
   skipped. It is never rounded up to "at least the minimum" — that would
   silently exceed the risk budget on a wide stop.

Because the stop is ATR-based, volume automatically shrinks when volatility
rises. That is the point: the money at risk stays constant, the size does not.

## 4. Stacking into a trend

(`InpMaxPositions`, `InpAddStepAtr`, `InpAddOnlyInProfit`, `InpCooldownSeconds`)

The first clip goes on as soon as a trigger fires. Each additional clip needs:

* fewer than `InpMaxPositions` clips already open in that direction,
* the existing clips in that direction to be showing an open profit
  (`InpAddOnlyInProfit`),
* price to have advanced at least `InpAddStepAtr × ATR` beyond the *best* entry
  already taken in that direction,
* `InpCooldownSeconds` to have elapsed since the last entry,
* a fresh trigger — adds are not automatic.

Adds are gated on price moving **in your favour**. There is deliberately no way
to configure adding into a loss.

## 5. Managing the position

Checked on every tick, in this order:

1. **Forced flatten** — the Friday cut-off, or a tripped breaker with
   `InpFlattenOnHalt` on.
2. **Flip exit** (`InpExitOnFlip`) — the entry-timeframe trend has turned
   against the position. On a trend follower this is usually the real exit;
   the stop is the insurance.
3. **Time exit** (`InpMaxHoldSeconds`) — a clip that has neither hit its target
   nor its stop within the limit is closed. A scalp that stops scalping is a
   position you did not intend to hold.
4. **Missing-stop rescue** — if a position somehow has no stop, one is attached.
5. **Partial close** (`InpPartialClosePct`, `InpPartialTriggerAtr`) — bank part
   of the clip once it is up `InpPartialTriggerAtr × ATR`, and let the rest run.
   Hedging accounts only; skipped if either the slice or the remainder would
   fall below the symbol's minimum volume.
6. **Break-even** (`InpBreakEvenAtr`, `InpBreakEvenOffsetPts`) — move the stop
   to entry plus a small offset that covers the spread.
7. **Trailing** (`InpTrailMode`, `InpTrailAtr`, `InpTrailStartAtr`) — either a
   fixed ATR distance behind price, or a distance behind the fast EMA, which
   follows the trend structure more closely and gives the move more room.

Stops only ever move in the profitable direction, are clamped to the broker's
minimum stop distance, and are skipped entirely while the position sits inside
the broker's freeze level.

## 6. Breakers

(`InpDailyLossPercent`, `InpDailyProfitPercent`, `InpMaxDrawdownPercent`,
`InpMaxConsecLosses`, `InpMaxTradesPerDay`, `InpMinFreeMarginPct`)

The daily loss, daily profit and drawdown limits are *latching*: once tripped,
new entries stop until the next server day. The losing-streak and trade-count
limits are re-evaluated continuously, so they release on their own. Streaks are
counted from this EA's own closed deals (matched by magic number and symbol),
so a restart does not reset them.

Open positions keep being managed while a breaker is active. With
`InpFlattenOnHalt` they are closed as well.

## Tuning notes

* **Symbol first, parameters second.** The strategy needs the spread to be
  small relative to the ATR of the entry timeframe. On a symbol where the
  spread is a quarter of the ATR, no parameter set rescues it — that is what
  `InpMaxSpreadAtr` is there to tell you.
* **`InpAdxMin` is the main quality dial.** Raising it trades less and better;
  lowering it trades more and worse. Move it before you touch the EMAs.
* **`InpStopLossAtr` and `InpTakeProfitAtr` move together.** A 1.2 / 1.8 pair
  needs roughly a 45 % hit rate to break even before costs; if you tighten the
  target, you need a correspondingly higher hit rate.
* **Slower entry timeframe = fewer, better trades.** M5 with an H1 bias is a
  reasonable, calmer configuration of the same logic.
