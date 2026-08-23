# RangeReverter — strategy reference

Everything the EA decides, in the order it decides it. Rule names in
parentheses are the inputs that control them.

RangeReverter is the companion to TrendScalper and its exact opposite.
TrendScalper needs `ADX ≥ 20` and two EMAs stacked and sloping; RangeReverter
needs `ADX ≤ 22` and a higher timeframe going nowhere. Run on the same symbol
with different magic numbers, they cover opposite halves of the day — but see
[Running both](#running-both) before you do.

## The one thing that matters

A mean-reversion system makes many small winners and dies on one loser: the
fade that was held through a trend. Almost every rule below exists to prevent
that single failure, and there are four of them:

1. **The regime gate** — never open a fade unless the market is measurably
   not trending (`InpAdxMax`, `InpHtfFlatAtr`, `InpBandExpansionMax`).
2. **The ride veto** — price closing outside a band repeatedly is a trend leg
   walking the band, not an extreme (`InpMaxRideBars`).
3. **The regime exit** — close what is already open the moment the range
   breaks (`InpExitOnRegimeBreak`, `InpAdxExit`, `InpBreakExitAtr`).
4. **No averaging down** — `InpMaxPositions` defaults to 1.

Loosen any of them and the equity curve gets smoother right up until it
doesn't.

## 1. Is the market ranging?

Three vetoes, all measured on the last *closed* bar so nothing repaints.

**Trend strength** (`InpAdxMax`)
ADX on the entry timeframe must be at or below `InpAdxMax`. This is the mirror
of TrendScalper's `InpAdxMin` and it is the single most important filter here.

**Higher-timeframe flatness** (`InpTrendTF`, `InpHtfEmaFast`, `InpHtfEmaSlow`,
`InpHtfFlatAtr`, `InpUseHtfFilter`)
The gap between the two higher-timeframe EMAs, divided by that timeframe's own
ATR, must stay under `InpHtfFlatAtr`. Dividing by ATR is what makes the number
portable: "the EMAs are 1 ATR apart" means the same thing on EURUSD and on
gold, where "the EMAs are 30 points apart" does not. With
`InpUseHtfFilter = false` this layer is skipped.

**Bands not opening up** (`InpBandExpansionMax`)
The current Bollinger width against the average width of the preceding 20
bars. A ratio above `InpBandExpansionMax` means volatility is expanding, which
is what the first minute of a breakout looks like from inside a range. Set to
`0` to disable.

## 2. Is the trip worth taking?

This is the gate that has no equivalent in a trend system, and it is the one
that will reject the most bars on an expensive symbol.

**The edge** is the distance from the band to the middle band — the journey the
trade is betting on. It must clear two floors:

| Floor | Input | Default | Why |
|---|---|---|---|
| ATR | `InpMinEdgeAtr` | `0.60` | Bands hugging price mean there is nothing to collect |
| Spread multiples | `InpMinEdgeSpreads` | `4.0` | The round trip has to pay for itself several times over |

The spread floor is the honest one. If the mean is four spreads away, a
strategy that wins 65 % of the time still loses money after costs. When this
gate blocks most of your bars, the EA is not misconfigured — it is telling you
this symbol cannot be faded at this broker's pricing. The start-up block prints
the current figure:

```
Edge now: band-to-mean 0.00081 = 1.84 x ATR = 8.1 spreads (floors 0.60 ATR / 4.0 spreads)
```

## 3. Is price actually at an extreme?

**The band** (`InpBandPeriod`, `InpBandDeviation`)
Price is at the lower band if the ask has traded to or through it, or if the
last closed bar's low pierced it. Upper band, mirrored, using the bid. Using
the price we would actually transact at — ask to buy, bid to sell — means the
spread cannot flatter the signal. A bar that pierced *both* bands says nothing
about direction and is skipped.

**Ride veto** (`InpMaxRideBars`)
Consecutive closed bars finishing outside the band on the side being faded. At
the default of `1`, two closes outside vetoes the trade. This is the difference
between "price poked the band" and "price is walking down the band", and the
second one is a trend.

**Knife veto** (`InpMaxBarAtr`)
If the last closed bar spanned more than `InpMaxBarAtr × ATR`, stand aside.
Something happened; wait for the next bar to find out what.

**Momentum confirmation** (`InpRsiPeriod`, `InpRsiOversold`, `InpRsiOverbought`)
RSI must be stretched the same way price is: at or below `InpRsiOversold` to
buy the lower band, at or above `InpRsiOverbought` to sell the upper one.
Price at a band with RSI at 50 is a band that has drifted, not an extreme.

## 4. Trigger

`InpEntryMode` picks one, the other, or whichever fires first. Both are checked
against the live bid/ask, so an entry can happen mid-bar.

**Touch** (`RR_ENTRY_TOUCH`, `InpTouchBufferAtr`)
Fade the moment the ask trades `InpTouchBufferAtr × ATR` through the lower band
(or the bid through the upper). Earliest fill, worst confirmation.

**Rejection bar** (`RR_ENTRY_REJECT`)
Wait for a closed bar that pierced the band and closed back *inside* it, then
enter when price takes out that bar's high (for a long). Later fill, and the
bar's extreme gives the stop somewhere sensible to sit. This is the safer of
the two in a market that sometimes trends.

## 5. Size

(`InpLotMode`, `InpRiskPercent`, `InpMaxLots`, `InpMaxTotalLots`)

Identical to TrendScalper: the stop price is computed first, the cost of that
stop per lot comes from `OrderCalcProfit`, and volume is the largest that keeps
the loss inside `InpRiskPercent` of equity, rounded **down** to the broker's
volume step. Below the symbol minimum, the trade is skipped rather than
up-sized.

## 6. Stop and target

**Stop** (`InpStopLossAtr`, `InpStopBeyondBandAtr`)
Two candidates, and the **further** one wins: `InpStopLossAtr × ATR` from the
entry, and `InpStopBeyondBandAtr × ATR` outside the band being faded. The
second exists because band pierces overshoot; a stop just past the band is a
stop placed exactly where the noise is.

**Target** (`InpTargetMode`, `InpTargetMidFraction`, `InpTakeProfitAtr`)
In the default mean mode, the target is `InpTargetMidFraction` of the way from
the entry to the middle band. The default `0.80` leaves the last fifth of the
move on the table deliberately — the mean is where the *other* side starts
finding the trade attractive, and getting filled there is not reliable.

**Reward/risk floor** (`InpMinRewardRisk`)
If the target is less than `InpMinRewardRisk ×` the stop distance, the entry is
skipped. A mean reverter can live below 1.0 — it wins often — but not below
about 0.4.

**The moving mean** (`InpTrackMean`)
The middle band is a moving average, so it moves while the trade is open. With
`InpTrackMean` on, the target follows it — **but only inwards**. A mean drifting
towards the position pulls the target closer and the trade finishes sooner; a
mean drifting away is the range failing, and being greedy about it is how a
winner turns into a loser. If the mean arrives at the position, the EA closes
at market rather than leaving a target the server would refuse.

## 7. Managing the open fade

The ladder, in the order it runs:

1. **Forced flatten** — the Friday cut-off, a tripped breaker, or EA removal.
2. **Regime break** (`InpExitOnRegimeBreak`, `InpAdxExit`, `InpBreakExitAtr`) —
   ADX at or above `InpAdxExit`, or price running `InpBreakExitAtr × ATR` past
   the band that was faded. Either way, the premise the trade was opened on no
   longer holds. **This is the rule that keeps the strategy alive.**
3. **Time exit** (`InpMaxHoldSeconds`) — a reversion that has not happened in
   two hours is not going to.
4. **Rescue stop and target** — if the server rejected either when the position
   was opened, attach it now. A fade is never left unprotected, and a fade with
   no target would silently never reach any of the percentage rules below.
5. **The mean** (`InpTrackMean`) — see above.
6. **Partial** (`InpPartialClosePct`, `InpPartialTriggerPct`) — off by default,
   because the journey is short enough that halving it twice leaves nothing.
7. **Break-even and trail** (`InpBreakEvenPct`, `InpTrailMode`,
   `InpTrailStartPct`) — both are measured as a **percentage of the way to the
   target**, not in ATR. The trade is a bet on one specific journey, so progress
   along that journey is the natural unit.

## Stacking, and why it is off

`InpMaxPositions` defaults to `1`.

In TrendScalper, extra clips are added *into* a move that is going well. Here,
by construction, price at a further extreme means the first clip is **losing**.
Adding there is averaging down — the mechanism behind essentially every retail
account that has ever gone to zero in a range that turned out to be a trend.

The input exists because sometimes you know what you are doing. If you raise
it, the EA warns at start-up, requires `InpAddStepAtr > 0`, and still enforces
`InpMaxTotalLots`. It will not save you from the trade where it does not work.

## Running both

TrendScalper and RangeReverter on the same symbol is a reasonable idea: their
regime filters are near-complements, so they mostly do not trade at the same
time. Two things to get right:

* **Different `InpMagic` per instance, always.** Each EA only ever sees, manages
  and closes positions carrying its own magic on its own symbol. Two instances
  sharing a magic will fight over the same positions.
* **Risk is per instance, not per account.** Two EAs at 0.25 % each can be in
  the market together during the handover between regimes, and their positions
  will be pointing in opposite directions. Budget for the sum.

There is a period between "trending" and "ranging" where ADX sits between the
two thresholds and neither EA trades. That gap is intentional. Narrowing it by
raising `InpAdxMax` above TrendScalper's `InpAdxMin` means both EAs take
positions in the same ambiguous conditions, in opposite directions.

## If it takes no trades

Same machinery as TrendScalper: a self-contained report is written every time
the EA stops, at any log level, in the tester too.

```
%APPDATA%\MetaQuotes\Terminal\Common\Files\RangeReverter_<SYMBOL>_diagnostics.txt
```

The verdict names the gate that blocked the most bars and what to do about it.
The three you should expect to see most:

| Tag | What it means |
|---|---|
| `ADX above range ceiling` | The market trended. This EA standing aside is it working. |
| `edge does not cover the spread` | The trip to the mean is not worth the cost here. Slower timeframe, or a different symbol. |
| `price inside the bands` | Everything passed; price just never reached an extreme. Lower `InpBandDeviation` or use a faster `InpEntryTF`. |

A tally dominated by the first two is not a misconfiguration. It is the EA
declining to trade a market it has no edge in, which over a year is worth more
than any parameter you could tune.
