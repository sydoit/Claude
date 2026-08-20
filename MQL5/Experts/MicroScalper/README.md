# MicroScalperEA

A production-ready micro-scalping Expert Advisor for MetaTrader 5.

## Installation

1. Copy `MicroScalperEA.mq5` into `<MT5 data folder>/MQL5/Experts/MicroScalper/`
   (open the data folder from the terminal via *File → Open Data Folder*).
2. In MetaEditor press **F7** to compile. It requires only the bundled standard
   library (`Trade\Trade.mqh`, `Trade\SymbolInfo.mqh`) — no external dependencies.
3. Drag the EA onto a chart and enable **AutoTrading**.

## How it works

| Stage | Behaviour |
| --- | --- |
| Signal | Fast/slow EMA cross evaluated on **closed** bars only (indices 1 and 2), so it cannot repaint. Optional RSI band filter rejects entries into an exhausted move. |
| Spread filter | `IsSpreadOk()` compares live `Ask - Bid` against `MaxSpread` (points). Checked before the signal *and* again immediately before the order is sent. |
| Concurrency | Strictly one position per symbol + `MagicNumber`. Leftover pending orders with the same magic also block new entries. |
| Exits | Fixed `TakeProfit` / `StopLoss` in points, attached server-side at entry, so the trade stays protected if the terminal disconnects. |
| Sizing | Fixed `Lotsize`, or risk-based sizing from `RiskPercent` using the broker's own tick value. Volume is clamped to min/max and snapped down to the volume step. |
| Safety | Prices snapped to the symbol tick grid then normalised to `_Digits`; broker `SYMBOL_TRADE_STOPS_LEVEL` enforced; free margin checked with `OrderCalcMargin` before sending. |
| Logging | Every rejection prints the broker retcode, its description, `GetLastError()`, and the volume/price/SL/TP/spread of the attempt. |

## Ask/Bid orientation

* **BUY** — opens at **Ask**, closes at Bid → SL below entry, TP above entry.
* **SELL** — opens at **Bid**, closes at Ask → SL above entry, TP below entry.

## Key inputs

| Input | Default | Notes |
| --- | --- | --- |
| `InpLotSize` | 0.01 | Fixed volume in lots. |
| `InpTakeProfit` | 60 | Points. `0` disables the TP. |
| `InpStopLoss` | 40 | Points. `0` disables the SL (not allowed with auto lot). |
| `InpMaxSpread` | 20 | Points. `0` disables the spread filter. |
| `InpSlippage` | 10 | Points of deviation passed to `CTrade`. |
| `InpMagicNumber` | 20250820 | Must be unique per EA instance. |
| `InpSignalTF` | M1 | Signal timeframe. |
| `InpOneTradePerBar` | true | One entry attempt per completed bar. |

## Notes before going live

* Point values are broker-specific: on a 5-digit FX symbol 20 points = 2.0 pips.
  Re-tune `MaxSpread`, `StopLoss` and `TakeProfit` per symbol.
* Scalping is highly sensitive to commission and execution quality — backtest
  with **Every tick based on real ticks** and a realistic commission, then
  forward-test on a demo account before risking capital.
* Some brokers restrict scalping or enforce a minimum holding time; check your
  account terms.
