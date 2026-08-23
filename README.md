# Automated trading systems for MetaTrader 5

Two Expert Advisors that trade opposite market regimes, sharing the same risk
engine, session filters and diagnostics.

| | **TrendScalper** | **RangeReverter** |
|---|---|---|
| Trades when | the market trends (`ADX ≥ 20`) | the market does not (`ADX ≤ 22`) |
| Direction | with the move | against the extreme |
| Signal | EMA stack + slope, pullback or micro-breakout | Bollinger band touch or rejection, RSI stretched |
| Target | `1.8 × ATR` | back to the middle band, which the target follows |
| Adds to a position | into strength, up to 4 clips | never — averaging down is off by default |
| The way it fails | chop, paying the spread repeatedly | one fade held through a trend |
| Docs | [`docs/STRATEGY.md`](docs/STRATEGY.md) | [`docs/RANGEREVERTER.md`](docs/RANGEREVERTER.md) |

Their regime filters are near-complements, so on the same symbol they mostly do
not trade at the same time. Give every instance its own `InpMagic` — see
[Running more than one chart](#running-more-than-one-chart).

**Trading real money with these — or any — automated system can lose money
quickly. Run them on a demo account until you understand their behaviour on
your broker, symbol and spread.** See [Before you go live](#before-you-go-live).

---

# TrendScalper

An Expert Advisor that trades small clips, quickly, in the direction of the
prevailing trend. It waits for a higher-timeframe bias and a same-direction
trend on the entry timeframe, enters on a pullback that resumes or a micro
breakout, then manages the position with an ATR stop that moves to break-even
and trails. Every entry is sized from a fixed slice of equity, and a set of
account-level breakers stops trading when the day goes wrong.

## What it actually does

```
 higher timeframe   entry timeframe        trigger              management
 ────────────────   ───────────────        ───────              ──────────
 EMA 20 vs EMA 50   EMA 12 vs EMA 34   pullback to the EMA   ATR stop
 gives the bias     + slope, ADX ≥ 20  that resumes, or a    → break-even
        │                    │         break of the last     → partial close
        └────── agree? ──────┘         N bars                → ATR trail
                   │                          │              → flip / time exit
                   └──────────────────────────┴──────────────────────┘
                                   small clip in
```

* **Small size by design.** Default risk is 0.25 % of equity per clip, capped
  at 0.10 lots, with a 0.50-lot ceiling on total open volume.
* **Adds into strength, never into weakness.** Extra clips are only opened
  after price has advanced a configurable ATR step in your favour and the
  existing clips are profitable. There is no martingale and no averaging down.
* **Fast, but not frantic.** Triggers are evaluated against the live bid/ask so
  the EA can act inside a bar, with a cooldown between entries so a single
  volatile minute cannot fill the book.
* **Always protected.** Orders go out with a stop attached; if a broker rejects
  it, the next tick attaches one. Positions are never left naked.

## Files

| Path | Purpose |
|---|---|
| `MQL5/Experts/TrendScalper/TrendScalper.mq5` | The EA: inputs, wiring, tick loop |
| `MQL5/Include/TrendScalper/Config.mqh` | Settings struct, enums, input validation |
| `MQL5/Include/TrendScalper/SignalEngine.mqh` | Trend detection and entry triggers |
| `MQL5/Include/TrendScalper/RiskManager.mqh` | Position sizing and the daily breakers |
| `MQL5/Include/TrendScalper/TradeExecutor.mqh` | Order placement, trailing, exits |
| `MQL5/Include/TrendScalper/Filters.mqh` | Sessions, blackouts, spread, cooldown |
| `MQL5/Include/TrendScalper/Dashboard.mqh` | On-chart status panel |
| `MQL5/Include/TrendScalper/Utils.mqh` | Symbol metadata, lot/price normalisation |
| `MQL5/Include/TrendScalper/Logger.mqh` | Leveled logging |
| `MQL5/Include/TrendScalper/Diagnostics.mqh` | Tally of why entries were or were not taken |
| `presets/*.set` | Starting points for a few instruments |
| `docs/STRATEGY.md` | The trading logic, rule by rule |
| `docs/BACKTESTING.md` | How to test it without fooling yourself |

RangeReverter lives in `MQL5/Experts/RangeReverter/` and
`MQL5/Include/RangeReverter/` with the same module layout. The two include
trees are deliberately independent copies rather than a shared library, so
either EA can be installed on its own by copying one folder.

## Install

1. In MetaTrader 5: **File → Open Data Folder**. That opens `…/Terminal/<hash>/`.
2. Copy the contents of this repo's `MQL5/` folder into the terminal's `MQL5/`
   folder, keeping the structure:
   * `MQL5/Experts/TrendScalper/TrendScalper.mq5`
   * `MQL5/Include/TrendScalper/*.mqh`
   * `MQL5/Experts/RangeReverter/RangeReverter.mq5` (optional)
   * `MQL5/Include/RangeReverter/*.mqh` (optional)
3. Open MetaEditor (**F4**), open `TrendScalper.mq5`, press **F7** to compile.
   It should report `0 errors, 0 warnings`. Repeat for `RangeReverter.mq5` if
   you copied it.
4. Back in the terminal, refresh the Navigator, drag **TrendScalper** onto a
   chart of the symbol you want to trade.
5. On the **Common** tab tick **Allow Algo Trading**, set the inputs, press OK.
6. Make sure the terminal's **Algo Trading** button is green.

Requires MetaTrader 5 (build 2085 or newer). MT4 is not supported — the code
uses the MQL5 position model and `CTrade`.

## Loading a preset

MT5's Load dialog opens in `MQL5/Presets` by default, so copy the `.set` files
there once (**File → Open Data Folder → MQL5 → Presets**) and they appear in the
list from then on. You can also just browse to wherever you cloned this repo.

**In the Strategy Tester** — this is the one you want for a backtest:

1. **View → Strategy Tester** (Ctrl+R).
2. Pick **TrendScalper** as the Expert, then set Symbol, Period and the date
   range. For `NVDA_M5_shares.set`, set Period to **M5** and Modelling to
   *Every tick based on real ticks*.
3. Open the **Inputs** tab and load the `.set`. Where that control lives
   depends on your build: older testers have **Load** / **Save** buttons under
   the parameter grid; newer ones moved it to the **right-click context menu**
   inside the grid. If neither appears, copy the `.set` into `MQL5/Presets`
   first — some builds only list presets already in that folder.
4. Check the values populated, then **Start**.

**On a live or demo chart** — the properties dialog has kept its Load/Save
buttons more consistently than the tester has:

1. Drag **TrendScalper** onto the chart of the symbol you want to trade.
2. In the dialog that opens, go to the **Inputs** tab and click **Load**.
3. Choose the `.set`, then **OK**.

**If you cannot find the control at all**, type the values in by hand — click a
**Value** cell in the grid and edit it. A `.set` is plain text, so you can read
the values straight out of it, and only a handful differ from the defaults.
The presets are `EURUSD_M1_conservative.set`, `XAUUSD_M5_wider.set` and
`NVDA_M5_shares.set` for TrendScalper, and `EURUSD_M5_range.set` and
`XAUUSD_M15_range.set` for RangeReverter. A preset only loads into the EA it
was written for.

For `NVDA_M5_shares.set` just three of them decide whether the EA trades at
all: `InpSessions` (clear it to blank), `InpMaxLots` = `0` and
`InpMaxTotalLots` = `0`. The rest are tuning.

To keep your own tuning, click **Save** on that same Inputs tab and write a new
`.set` — don't edit the repo ones in place, so you can always diff against the
starting point.

Two things a `.set` file does *not* carry, because MT5 does not store them
there: the **symbol** and the **timeframe/date range**. Those are tester or
chart settings and must be set separately — a preset named for NVDA will
happily load onto a EURUSD chart. Note also that `InpEntryTF` and `InpTrendTF`
inside the preset control which timeframes the *signals* use, independently of
the chart or tester period.

## Key inputs

Everything has a default that works; these are the ones worth thinking about.

### Size and risk

| Input | Default | Meaning |
|---|---|---|
| `InpLotMode` | `TS_LOT_RISK` | Size from risk, or use a fixed volume |
| `InpRiskPercent` | `0.25` | Percent of equity risked per clip |
| `InpMaxLots` | `0.10` | Hard cap on a single clip |
| `InpMaxTotalLots` | `0.50` | Hard cap on total open volume |
| `InpMaxPositions` | `4` | How many clips may be stacked in a trend |
| `InpAddStepAtr` | `0.75` | Price must advance this many ATR before adding |

Volume is derived from the stop, not the other way round: the EA computes what
the stop distance costs per lot (via `OrderCalcProfit`, so contract size and
currency conversion are the broker's own numbers), then buys the largest volume
whose loss at the stop stays inside the risk budget, rounded **down** to the
broker's volume step. If that lands below the symbol minimum, the trade is
skipped rather than up-sized.

### Signal

| Input | Default | Meaning |
|---|---|---|
| `InpEntryTF` | `M1` | Timeframe the triggers run on |
| `InpTrendTF` | `M15` | Timeframe that sets the bias |
| `InpEmaFast` / `InpEmaSlow` | `12` / `34` | Trend EMAs on the entry timeframe |
| `InpAdxMin` | `20` | Below this, the market is called "chop" and skipped |
| `InpEntryMode` | `EITHER` | Pullback, breakout, or whichever fires first |
| `InpTiming` | `EVERY_TICK` | Tick-level entries, or one evaluation per bar |

### Exits

| Input | Default | Meaning |
|---|---|---|
| `InpStopLossAtr` | `1.20` | Stop distance in ATR |
| `InpTakeProfitAtr` | `1.80` | Target distance in ATR (`InpUseTakeProfit` to disable) |
| `InpBreakEvenAtr` | `0.80` | Move the stop to entry after this much profit |
| `InpTrailAtr` | `1.00` | Trailing distance once trailing starts |
| `InpPartialClosePct` | `50` | Bank half the clip at `InpPartialTriggerAtr` |
| `InpMaxHoldSeconds` | `3600` | Close a clip that has gone nowhere |

### Guards

| Input | Default | Meaning |
|---|---|---|
| `InpMaxSpreadPoints` | `20` | Skip entries when the spread is wide |
| `InpMaxSpreadAtr` | `0.25` | …and when it is large relative to ATR |
| `InpDailyLossPercent` | `2.0` | Stop trading for the day after this loss |
| `InpDailyProfitPercent` | `3.0` | Stop trading for the day after this gain |
| `InpMaxDrawdownPercent` | `10.0` | Stop trading at this equity drawdown |
| `InpMaxConsecLosses` | `4` | Pause after a losing streak |
| `InpMaxTradesPerDay` | `40` | Daily entry cap |
| `InpSessions` | `07:00-11:00,13:00-17:00` | Server-time windows; blank means 24h |
| `InpFridayCloseHour` | `20` | Flatten and stop on Friday at this hour |

`InpSessions` and `InpBlackout` take a comma-separated list of `HH:MM-HH:MM`
windows in **broker server time**, and windows may wrap past midnight
(`22:00-02:00`). Use `InpBlackout` to sit out scheduled news.

## If it takes no trades

The EA writes a self-contained report to a text file every time it stops —
start-up facts, a verdict, and the tally — so you never have to dig through the
Journal tab:

```
%APPDATA%\MetaQuotes\Terminal\Common\Files\TrendScalper_<SYMBOL>_diagnostics.txt
```

Paste that path into Explorer's address bar (on macOS:
`~/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/users/…/Common/Files/`).
The same text goes to the Journal at any log level, in the tester as well as
live.

**If that file does not appear at all, you are running a stale compiled EA.**
Re-copy `MQL5/Include/TrendScalper/` (it gained new files) and recompile with
F7. The start-up block names the build — anything that does not say
`build 1.02 (diagnostics enabled)` is the old one.

The report opens with a verdict:

```
VERDICT: no entry was ever attempted.

The gate that blocked the most bars (94.3% of them) was:
  outside InpSessions window

  InpSessions never opens while this symbol is quoted. It is in BROKER
  SERVER TIME. Clear it to blank and let the broker's own session table
  gate trading.
```

followed by the full tally:

```
Reason                                      count     share
outside InpSessions window                  98214    94.31%
ADX below minimum                            4102     3.94%
sized volume below broker minimum             982     0.94%
> entered                                      37
```

Lines beginning with `>` are entry attempts; the rest are per-bar samples.

The two traps that cost a whole backtest, both of which the start-up block now
calls out explicitly:

**Sessions are in broker server time, not exchange time.** The default
`07:00-11:00,13:00-17:00` is shaped for the London/Frankfurt forex day. A
typical broker runs on EET, so the New York cash open at 09:30 ET is **16:30
server time** — the defaults miss almost the entire US stock session. On any
exchange-hours symbol (shares, index CFDs), set `InpSessions = ""` and let the
broker's own session table do the gating. Start-up prints the actual overlap:

```
Tradable minutes per weekday (broker session x InpSessions):
  Mon 30m  Tue 30m  Wed 30m  Thu 30m  Fri 30m
```

**"Lots" only means the same thing across forex pairs.** A share CFD is
usually quoted in shares, with a minimum and a step of 1. The forex-shaped
`InpMaxLots = 0.10` then floors to zero on every tick and no order can ever be
sized — silently, forever. The EA now raises an impossible cap to the broker
minimum and says so; even better, set `InpMaxLots = 0` and
`InpMaxTotalLots = 0` on such symbols and let `InpRiskPercent` govern size.
Start-up also checks the risk budget can afford one minimum lot at the
configured stop:

```
Sizing: 0.25% of equity = 25.00, the 1.20 x ATR stop costs 0.62 per lot
        -> wants 40.3226 lots (broker minimum 1.00)
```

If that "wants" figure is below the broker minimum, every entry is skipped —
raise `InpRiskPercent`, fund the account higher, or trade a lower-priced
instrument.

---

# RangeReverter

The mean-reversion side. It fades the edges of a range back towards the middle
Bollinger band, and spends most of its time refusing to trade.

```
 regime                 edge                extreme            management
 ──────                 ────                ───────            ──────────
 ADX <= 22          band-to-mean must   price at a band     target = the mean
 HTF EMAs flat      clear an ATR floor  + RSI stretched     → follows it inwards
 bands not          AND several         + not being ridden  → break-even at 60%
 expanding          spreads             + no violent bar    → regime exit
        │                  │                    │           → time exit
        └──────────────────┴────────────────────┴──────────────────┘
                              fade it, once
```

* **Most of the work is deciding not to trade.** Three regime vetoes, two
  economic floors and three extremeness vetoes sit in front of the trigger. A
  diagnostics tally dominated by `ADX above range ceiling` or `edge does not
  cover the spread` is the EA working, not a misconfiguration.
* **The target follows the mean, but only closer.** The middle band moves while
  the trade is open. Drifting towards the position pulls the target in and ends
  the trade sooner; drifting away is the range failing, and the EA does not
  chase it.
* **There is a regime exit.** ADX waking up, or price running past the faded
  band, closes the position immediately. Mean reversion has exactly one fatal
  failure mode and this is the rule that addresses it.
* **No averaging down.** `InpMaxPositions` defaults to `1`. Raising it is
  allowed and the EA warns you about it at start-up.

Start from `presets/EURUSD_M5_range.set` or `presets/XAUUSD_M15_range.set`, and
read [`docs/RANGEREVERTER.md`](docs/RANGEREVERTER.md) for the rules in full.

Everything below about installing presets, sizing, the diagnostics file,
running several charts and going live applies to both EAs — the input names for
size, guards and schedule are deliberately identical. Where RangeReverter
differs is documented in its own file.

## Running more than one chart

Give every chart its **own `InpMagic`**. The EA only ever counts, manages and
closes positions carrying its own magic number on its own symbol, so two
instances with different magics coexist safely — but two instances sharing a
magic will fight over the same positions.

Risk inputs are per instance, not per account: four charts at 0.25 % each can
risk 1 % on a correlated move. Size accordingly.

## Before you go live

1. **Compile clean**, then run the Strategy Tester on *Every tick based on real
   ticks* over at least several months. See `docs/BACKTESTING.md`.
2. **Forward-test on demo** on the same broker and account type you intend to
   use, for long enough to see a losing streak. Scalping results are dominated
   by spread, commission and execution — none of which a backtest models
   perfectly.
3. **Check the symbol's cost.** If the spread is a large fraction of the ATR on
   your entry timeframe, this strategy cannot win there no matter how it is
   tuned. Raise the timeframe or pick a tighter instrument.
4. **Start at the minimum size** and only raise `InpRiskPercent` once live
   results match the demo.
5. Confirm your broker permits scalping and EAs, and check the swap and
   commission on the symbol.

Automated trading carries real risk of loss, including losses larger than
expected during gaps, requotes or a broker outage. Nothing here is financial
advice, and no configuration of it is guaranteed to be profitable. You are
responsible for anything it does on your account.

## Known limitations

* **Netting accounts.** On a netting account the stacked clips merge into one
  position, so per-clip partial closes are disabled and stop management applies
  to the merged position. Hedging accounts get the full behaviour. The EA logs
  which mode it detected at start-up.
* **No news awareness.** `InpBlackout` is manual — the EA does not read an
  economic calendar.
* **Server time, not local time.** All schedule inputs use broker time, which
  may differ from yours by several hours and may shift with DST.
* **One symbol per instance.** The EA trades the chart it is attached to.
* **The defaults are forex-shaped.** Session windows and the lot caps assume a
  24-hour, 0.01-lot instrument. On shares, index CFDs or crypto, start from
  `presets/NVDA_M5_shares.set` and read the start-up block before judging the
  results.
