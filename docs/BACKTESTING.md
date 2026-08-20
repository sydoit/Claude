# Backtesting and forward-testing

A scalper's backtest is easy to get wrong in a way that looks profitable. This
is the sequence that avoids most of the traps.

## 1. Get honest data

In the Strategy Tester:

* **Model:** *Every tick based on real ticks*. Nothing else is meaningful for a
  strategy that enters mid-bar — "Open prices only" and "1 minute OHLC" will
  invent fills the EA could never get.
* **Period:** at least 6 months, and include a range-bound stretch, not only a
  trending one.
* **Deposit and leverage:** whatever your real account uses.
* **Spread:** *Current* uses the live spread; real-tick data carries its own
  spread, which is what you want. Do not test on a fixed 1-point spread.
* **Commission:** set it in the tester's symbol settings if your account is
  raw-spread. Ignoring commission on a high-frequency strategy is the single
  biggest way to fake a profitable curve.

## 2. First run: sanity, not profit

Run once with the defaults and read the journal, not the report. You are
checking that:

* the EA logged its symbol spec, risk line and account mode at start-up,
* trades have stops attached from the first tick,
* the number of trades is plausible for the period (thousands of trades on a
  few months of M1 means the filters are too loose),
* no repeated `Order attempt … failed` lines.

Set `InpTesterVerbose = true` and `InpLogLevel = TS_LOG_DEBUG` if you need to
see why signals are being rejected — but turn it back off, verbose logging
slows the tester by an order of magnitude.

## 3. Read the right numbers

In order of usefulness for this kind of system:

| Metric | What to want |
|---|---|
| Profit factor | > 1.2 *after* commission, otherwise there is no edge |
| Maximum equity drawdown | Small enough that you would keep the EA running |
| Number of trades | Enough to be statistically meaningful (hundreds) |
| Average trade | Must comfortably exceed the spread + commission |
| Longest losing streak | Compare with `InpMaxConsecLosses` |

An "average trade" close to the round-trip cost means the reported profit is
noise. Check it before anything else.

## 4. Optimise carefully, if at all

If you optimise, do it on a few parameters at a time and prefer the ones with a
broad plateau of decent results over a single sharp peak — a peak is a curve
fit and it will not survive contact with the market.

Reasonable ranges:

| Input | From | To | Step |
|---|---|---|---|
| `InpAdxMin` | 15 | 32 | 1 |
| `InpStopLossAtr` | 0.8 | 2.0 | 0.1 |
| `InpTakeProfitAtr` | 1.0 | 3.0 | 0.1 |
| `InpTrailAtr` | 0.6 | 2.0 | 0.1 |
| `InpBreakoutLookback` | 4 | 20 | 1 |
| `InpAddStepAtr` | 0.4 | 1.5 | 0.1 |

Leave the risk and guard inputs out of the optimisation. Optimising
`InpRiskPercent` optimises for the luckiest sequence of trades in the sample,
which is the opposite of what those inputs are for.

Then **walk it forward**: optimise on one period, test on the next untouched
period. If the out-of-sample result collapses, the parameters were fitted.

## 5. Forward-test on demo

Backtests cannot model requotes, variable slippage, weekend gaps or your
broker's execution speed — all of which matter more at this timescale than the
signal does. Run on demo, on the account type you intend to use, until you have
seen at least one losing streak and one high-volatility session.

Compare demo results with the backtest over the same dates. A large gap is
telling you the backtest was optimistic, and by how much.

## 6. Then go live small

Start at the smallest size the broker allows, with `InpDailyLossPercent` set
tight. Raise size only after live results track the demo for a meaningful
sample. Keep the daily and drawdown breakers on permanently — they are what
turns a bad day into a small bad day.
