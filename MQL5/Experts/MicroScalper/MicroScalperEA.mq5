//+------------------------------------------------------------------+
//|                                              MicroScalperEA.mq5   |
//|                                                                  |
//|  Micro-scalping Expert Advisor for MetaTrader 5.                 |
//|                                                                  |
//|  Strategy outline                                                |
//|  ----------------                                                |
//|  * Signal      : fast/slow EMA cross evaluated on CLOSED bars,    |
//|                  optionally confirmed by an RSI band filter so    |
//|                  we do not buy into an exhausted move.            |
//|  * Filters     : hard spread ceiling, one-position-per-magic,     |
//|                  optional trading session window, broker-side     |
//|                  stops-level compliance.                          |
//|  * Exits       : fixed TakeProfit / StopLoss in points, attached  |
//|                  to the position at entry time (server side), so  |
//|                  the trade is protected even if the terminal or   |
//|                  the EA goes offline.                             |
//|                                                                  |
//|  Everything price-related is normalised to the symbol tick size   |
//|  and to _Digits before it is sent to the server, and every trade  |
//|  request is logged with its retcode on failure.                   |
//+------------------------------------------------------------------+
#property copyright "MicroScalperEA"
#property link      ""
#property version   "1.00"
#property description "Micro-scalping EA: EMA cross entries, fixed point-based SL/TP, spread guard, one position per magic number."

//--- MetaTrader 5 standard trading library -------------------------
#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+
input group "=== Money management ==="
input double   InpLotSize          = 0.01;   // Lotsize (fixed volume, in lots)
input bool     InpAutoLot          = false;  // Auto lot: size from RiskPercent instead of Lotsize
input double   InpRiskPercent      = 0.5;    // Risk per trade (% of balance) when Auto lot is on

input group "=== Trade parameters (points) ==="
input int      InpTakeProfit       = 60;     // TakeProfit in points (0 = no TP)
input int      InpStopLoss         = 40;     // StopLoss   in points (0 = no SL)
input int      InpMaxSpread        = 20;     // MaxSpread  in points (0 = spread filter disabled)
input int      InpSlippage         = 10;     // Deviation / slippage in points

input group "=== Identification ==="
input ulong    InpMagicNumber      = 20250820; // MagicNumber (unique per EA instance)
input string   InpTradeComment     = "MicroScalper"; // Order comment

input group "=== Signal settings ==="
input ENUM_TIMEFRAMES InpSignalTF  = PERIOD_M1; // Signal timeframe
input int      InpFastEmaPeriod    = 5;      // Fast EMA period
input int      InpSlowEmaPeriod    = 20;     // Slow EMA period
input bool     InpUseRsiFilter     = true;   // Use RSI confirmation filter
input int      InpRsiPeriod        = 7;      // RSI period
input double   InpRsiUpperLimit    = 75.0;   // Do not buy above this RSI value
input double   InpRsiLowerLimit    = 25.0;   // Do not sell below this RSI value
input bool     InpOneTradePerBar   = true;   // Only one entry attempt per completed bar

input group "=== Session filter ==="
input bool     InpUseTimeFilter    = false;  // Restrict trading to a time window (server time)
input int      InpStartHour        = 7;      // Session start hour (0-23, server time)
input int      InpEndHour          = 20;     // Session end hour   (0-23, server time)

input group "=== Diagnostics ==="
input bool     InpVerboseLog       = true;   // Verbose journal logging

//+------------------------------------------------------------------+
//| GLOBALS                                                          |
//+------------------------------------------------------------------+
CTrade         trade;                  // trading wrapper from the standard library
CSymbolInfo    symbolInfo;             // symbol properties helper

int            g_handleFastEma = INVALID_HANDLE; // fast EMA indicator handle
int            g_handleSlowEma = INVALID_HANDLE; // slow EMA indicator handle
int            g_handleRsi     = INVALID_HANDLE; // RSI indicator handle

datetime       g_lastBarTime   = 0;    // open time of the last processed bar
datetime       g_lastTradeBar  = 0;    // open time of the bar on which we last traded

double         g_point         = 0.0;  // cached symbol point size
double         g_tickSize      = 0.0;  // cached symbol tick size
int            g_digits        = 0;    // cached symbol digits

//--- direction helper ---------------------------------------------
enum ENUM_SIGNAL
  {
   SIGNAL_NONE = 0,                    // no trade
   SIGNAL_BUY  = 1,                    // long setup
   SIGNAL_SELL = -1                    // short setup
  };

//+------------------------------------------------------------------+
//| Logging helper: only prints when verbose logging is enabled.     |
//| Errors are printed through Print() directly so they are never    |
//| suppressed.                                                      |
//+------------------------------------------------------------------+
void LogInfo(const string message)
  {
   if(InpVerboseLog)
      PrintFormat("[%s][%I64u] %s", _Symbol, InpMagicNumber, message);
  }

//+------------------------------------------------------------------+
//| Expert initialisation                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
//--- cache symbol properties once; they never change at runtime ----
   if(!symbolInfo.Name(_Symbol))
     {
      PrintFormat("ERROR: cannot select symbol %s. error=%d", _Symbol, GetLastError());
      return(INIT_FAILED);
     }
   symbolInfo.RefreshRates();

   g_digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_point    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(g_point <= 0.0)
     {
      Print("ERROR: symbol point size is zero - cannot continue.");
      return(INIT_FAILED);
     }
//--- some brokers report a zero tick size; fall back to point ------
   if(g_tickSize <= 0.0)
      g_tickSize = g_point;

//--- validate user inputs before doing anything else ---------------
   if(!ValidateInputs())
      return(INIT_PARAMETERS_INCORRECT);

//--- configure the trading object ---------------------------------
   trade.SetExpertMagicNumber(InpMagicNumber);          // tag every order with our magic
   trade.SetDeviationInPoints((ulong)InpSlippage);      // maximum accepted slippage
   trade.SetTypeFillingBySymbol(_Symbol);               // pick a filling mode the symbol supports
   trade.SetMarginMode();                               // use the account margin mode
   trade.LogLevel(InpVerboseLog ? LOG_LEVEL_ERRORS : LOG_LEVEL_NO);
   trade.SetAsyncMode(false);                           // synchronous: we want the retcode now

//--- create indicator handles -------------------------------------
   g_handleFastEma = iMA(_Symbol, InpSignalTF, InpFastEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_handleSlowEma = iMA(_Symbol, InpSignalTF, InpSlowEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);

   if(g_handleFastEma == INVALID_HANDLE || g_handleSlowEma == INVALID_HANDLE)
     {
      PrintFormat("ERROR: failed to create EMA handles. error=%d", GetLastError());
      return(INIT_FAILED);
     }

   if(InpUseRsiFilter)
     {
      g_handleRsi = iRSI(_Symbol, InpSignalTF, InpRsiPeriod, PRICE_CLOSE);
      if(g_handleRsi == INVALID_HANDLE)
        {
         PrintFormat("ERROR: failed to create RSI handle. error=%d", GetLastError());
         return(INIT_FAILED);
        }
     }

//--- remember the current bar so we do not fire on the first tick --
   g_lastBarTime = (datetime)SeriesInfoInteger(_Symbol, InpSignalTF, SERIES_LASTBAR_DATE);

   LogInfo(StringFormat("initialised. digits=%d point=%s tickSize=%s stopsLevel=%d freezeLevel=%d",
                        g_digits, DoubleToString(g_point, g_digits), DoubleToString(g_tickSize, g_digits),
                        (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
                        (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL)));

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialisation - always release indicator handles       |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_handleFastEma != INVALID_HANDLE)
      IndicatorRelease(g_handleFastEma);
   if(g_handleSlowEma != INVALID_HANDLE)
      IndicatorRelease(g_handleSlowEma);
   if(g_handleRsi != INVALID_HANDLE)
      IndicatorRelease(g_handleRsi);

   LogInfo(StringFormat("deinitialised. reason=%d", reason));
  }

//+------------------------------------------------------------------+
//| Sanity-check every user input. A misconfigured scalper is far    |
//| more dangerous than one that refuses to start.                   |
//+------------------------------------------------------------------+
bool ValidateInputs()
  {
   bool ok = true;

   const double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(!InpAutoLot)
     {
      if(InpLotSize < minLot || InpLotSize > maxLot)
        {
         PrintFormat("ERROR: Lotsize %.4f is outside the symbol range [%.4f .. %.4f].",
                     InpLotSize, minLot, maxLot);
         ok = false;
        }
     }
   else
     {
      if(InpRiskPercent <= 0.0 || InpRiskPercent > 100.0)
        {
         PrintFormat("ERROR: RiskPercent %.2f must be in (0 .. 100].", InpRiskPercent);
         ok = false;
        }
      if(InpStopLoss <= 0)
        {
         Print("ERROR: Auto lot requires a non-zero StopLoss to size the position.");
         ok = false;
        }
     }

   if(InpTakeProfit < 0 || InpStopLoss < 0 || InpMaxSpread < 0 || InpSlippage < 0)
     {
      Print("ERROR: TakeProfit, StopLoss, MaxSpread and Slippage must be zero or positive.");
      ok = false;
     }

   if(InpFastEmaPeriod < 1 || InpSlowEmaPeriod < 1 || InpFastEmaPeriod >= InpSlowEmaPeriod)
     {
      PrintFormat("ERROR: EMA periods invalid (fast=%d slow=%d). Fast must be >=1 and < slow.",
                  InpFastEmaPeriod, InpSlowEmaPeriod);
      ok = false;
     }

   if(InpUseRsiFilter)
     {
      if(InpRsiPeriod < 2)
        {
         PrintFormat("ERROR: RSI period %d must be >= 2.", InpRsiPeriod);
         ok = false;
        }
      if(InpRsiLowerLimit < 0.0 || InpRsiUpperLimit > 100.0 || InpRsiLowerLimit >= InpRsiUpperLimit)
        {
         PrintFormat("ERROR: RSI limits invalid (lower=%.1f upper=%.1f).",
                     InpRsiLowerLimit, InpRsiUpperLimit);
         ok = false;
        }
     }

   if(InpUseTimeFilter)
     {
      if(InpStartHour < 0 || InpStartHour > 23 || InpEndHour < 0 || InpEndHour > 23)
        {
         Print("ERROR: session hours must be in the 0..23 range.");
         ok = false;
        }
     }

   if(InpMagicNumber == 0)
      Print("WARNING: MagicNumber is 0. Positions opened manually may be counted as this EA's.");

   return(ok);
  }

//+------------------------------------------------------------------+
//| FILTER: spread check                                             |
//|                                                                  |
//| Returns true when the live Ask-Bid spread is at or below the     |
//| MaxSpread threshold (expressed in points). A MaxSpread of 0      |
//| disables the filter entirely.                                    |
//+------------------------------------------------------------------+
bool IsSpreadOk()
  {
   if(InpMaxSpread <= 0)
      return(true);                                   // filter disabled by the user

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
     {
      PrintFormat("ERROR: SymbolInfoTick failed for %s. error=%d", _Symbol, GetLastError());
      return(false);                                  // no quote -> never trade
     }

   if(tick.ask <= 0.0 || tick.bid <= 0.0)
      return(false);                                  // stale / empty quote

//--- spread in points, rounded to the nearest whole point ----------
   const double spreadPoints = (tick.ask - tick.bid) / g_point;

   if(spreadPoints > (double)InpMaxSpread)
     {
      if(InpVerboseLog)
         LogInfo(StringFormat("spread filter blocked entry: %.1f pts > max %d pts",
                              spreadPoints, InpMaxSpread));
      return(false);
     }

   return(true);
  }

//+------------------------------------------------------------------+
//| FILTER: is there already a position for this symbol + magic?     |
//|                                                                  |
//| The EA is strictly single-position: it never pyramids and never  |
//| hedges itself.                                                   |
//+------------------------------------------------------------------+
bool HasOpenPosition()
  {
   const int total = PositionsTotal();

   for(int i = total - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);       // also selects the position
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      return(true);                                    // one of ours is already running
     }

   return(false);
  }

//+------------------------------------------------------------------+
//| FILTER: pending orders belonging to this EA (defensive check;    |
//| this EA only sends market orders, but a leftover pending order   |
//| from a previous run must not be duplicated).                     |
//+------------------------------------------------------------------+
bool HasPendingOrder()
  {
   const int total = OrdersTotal();

   for(int i = total - 1; i >= 0; i--)
     {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
         continue;

      return(true);
     }

   return(false);
  }

//+------------------------------------------------------------------+
//| FILTER: trading session window (server time)                     |
//+------------------------------------------------------------------+
bool IsWithinTradingHours()
  {
   if(!InpUseTimeFilter)
      return(true);

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(InpStartHour == InpEndHour)
      return(true);                                    // degenerate window = 24h

   if(InpStartHour < InpEndHour)                       // e.g. 07:00 -> 20:00
      return(dt.hour >= InpStartHour && dt.hour < InpEndHour);

   return(dt.hour >= InpStartHour || dt.hour < InpEndHour); // overnight window
  }

//+------------------------------------------------------------------+
//| FILTER: is the terminal / account / symbol allowed to trade?     |
//+------------------------------------------------------------------+
bool IsTradingAllowed()
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
     {
      LogInfo("trading is disabled in the terminal (AutoTrading button).");
      return(false);
     }

   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
     {
      LogInfo("trading is disabled for this EA in its properties.");
      return(false);
     }

   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
     {
      LogInfo("trading is not allowed for this account.");
      return(false);
     }

   const ENUM_SYMBOL_TRADE_MODE mode =
      (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);

   if(mode != SYMBOL_TRADE_MODE_FULL && mode != SYMBOL_TRADE_MODE_LONGONLY &&
      mode != SYMBOL_TRADE_MODE_SHORTONLY)
     {
      LogInfo("symbol is close-only or disabled for trading.");
      return(false);
     }

   return(true);
  }

//+------------------------------------------------------------------+
//| Detect a freshly closed bar on the signal timeframe.             |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   const datetime currentBarTime =
      (datetime)SeriesInfoInteger(_Symbol, InpSignalTF, SERIES_LASTBAR_DATE);

   if(currentBarTime == 0 || currentBarTime == g_lastBarTime)
      return(false);

   g_lastBarTime = currentBarTime;
   return(true);
  }

//+------------------------------------------------------------------+
//| SIGNAL: fast/slow EMA cross on the two most recent CLOSED bars,  |
//| optionally confirmed by RSI.                                     |
//|                                                                  |
//| Buffer index 1 = last closed bar, index 2 = the one before it.   |
//| Index 0 (the forming bar) is deliberately ignored so the signal  |
//| cannot repaint.                                                  |
//+------------------------------------------------------------------+
ENUM_SIGNAL GetSignal()
  {
   double fast[], slow[];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);

//--- we need bars 1 and 2, so copy three values from index 0 -------
   if(CopyBuffer(g_handleFastEma, 0, 0, 3, fast) < 3 ||
      CopyBuffer(g_handleSlowEma, 0, 0, 3, slow) < 3)
     {
      PrintFormat("WARNING: indicator data not ready yet. error=%d", GetLastError());
      return(SIGNAL_NONE);
     }

   const bool crossedUp   = (fast[2] <= slow[2] && fast[1] > slow[1]);
   const bool crossedDown = (fast[2] >= slow[2] && fast[1] < slow[1]);

   if(!crossedUp && !crossedDown)
      return(SIGNAL_NONE);

//--- optional RSI confirmation: skip entries into an exhausted move-
   if(InpUseRsiFilter)
     {
      double rsi[];
      ArraySetAsSeries(rsi, true);

      if(CopyBuffer(g_handleRsi, 0, 0, 2, rsi) < 2)
        {
         PrintFormat("WARNING: RSI data not ready yet. error=%d", GetLastError());
         return(SIGNAL_NONE);
        }

      if(crossedUp && rsi[1] >= InpRsiUpperLimit)
        {
         LogInfo(StringFormat("buy cross rejected by RSI filter (rsi=%.2f >= %.2f)",
                              rsi[1], InpRsiUpperLimit));
         return(SIGNAL_NONE);
        }

      if(crossedDown && rsi[1] <= InpRsiLowerLimit)
        {
         LogInfo(StringFormat("sell cross rejected by RSI filter (rsi=%.2f <= %.2f)",
                              rsi[1], InpRsiLowerLimit));
         return(SIGNAL_NONE);
        }
     }

//--- respect a long-only / short-only symbol -----------------------
   const ENUM_SYMBOL_TRADE_MODE mode =
      (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);

   if(crossedUp  && mode == SYMBOL_TRADE_MODE_SHORTONLY)
      return(SIGNAL_NONE);
   if(crossedDown && mode == SYMBOL_TRADE_MODE_LONGONLY)
      return(SIGNAL_NONE);

   return(crossedUp ? SIGNAL_BUY : SIGNAL_SELL);
  }

//+------------------------------------------------------------------+
//| PRICE SAFETY: snap a price to the symbol tick grid and then to   |
//| _Digits. Sending a price that is not a multiple of the tick size |
//| is a classic source of "Invalid stops" rejections.               |
//+------------------------------------------------------------------+
double NormalizePrice(const double price)
  {
   if(price <= 0.0)
      return(0.0);

   const double snapped = MathRound(price / g_tickSize) * g_tickSize;
   return(NormalizeDouble(snapped, g_digits));
  }

//+------------------------------------------------------------------+
//| VOLUME SAFETY: clamp to [min,max] and snap to the volume step,   |
//| then round to the step's own precision.                          |
//+------------------------------------------------------------------+
double NormalizeVolume(const double volume)
  {
   const double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double       stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(stepLot <= 0.0)
      stepLot = minLot > 0.0 ? minLot : 0.01;

//--- the epsilon absorbs binary rounding so e.g. 0.01/0.01 never floors to 0
   double result = MathFloor(volume / stepLot + 1e-8) * stepLot;  // never round volume up

   result = MathMax(result, minLot);
   result = MathMin(result, maxLot);

//--- derive the number of decimals implied by the volume step ------
   const int volumeDigits = (int)MathMax(0.0, MathCeil(-MathLog10(stepLot)));

   return(NormalizeDouble(result, volumeDigits));
  }

//+------------------------------------------------------------------+
//| POSITION SIZING                                                  |
//|                                                                  |
//| Fixed lot by default. With Auto lot enabled the volume is        |
//| derived from RiskPercent of the balance and the StopLoss         |
//| distance, using the broker's own tick value so it works on FX,   |
//| metals, indices and crypto alike.                                |
//+------------------------------------------------------------------+
double CalculateLotSize(const int stopLossPoints)
  {
   if(!InpAutoLot || stopLossPoints <= 0)
      return(NormalizeVolume(InpLotSize));

   const double balance      = AccountInfoDouble(ACCOUNT_BALANCE);
   const double riskMoney    = balance * InpRiskPercent / 100.0;
   const double tickValue    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

   if(riskMoney <= 0.0 || tickValue <= 0.0 || g_tickSize <= 0.0)
     {
      PrintFormat("WARNING: cannot compute auto lot (risk=%.2f tickValue=%.5f). Falling back to Lotsize.",
                  riskMoney, tickValue);
      return(NormalizeVolume(InpLotSize));
     }

//--- money lost per 1.0 lot if the stop is hit ---------------------
   const double slDistance   = stopLossPoints * g_point;
   const double lossPerLot   = (slDistance / g_tickSize) * tickValue;

   if(lossPerLot <= 0.0)
     {
      Print("WARNING: computed zero loss-per-lot. Falling back to Lotsize.");
      return(NormalizeVolume(InpLotSize));
     }

   const double rawVolume = riskMoney / lossPerLot;
   const double volume    = NormalizeVolume(rawVolume);

   LogInfo(StringFormat("auto lot: balance=%.2f risk=%.2f slPts=%d lossPerLot=%.2f -> %.2f lots",
                        balance, riskMoney, stopLossPoints, lossPerLot, volume));

   return(volume);
  }

//+------------------------------------------------------------------+
//| Check that we can actually afford the trade before sending it.   |
//+------------------------------------------------------------------+
bool HasEnoughMargin(const ENUM_ORDER_TYPE orderType, const double volume, const double price)
  {
   double margin = 0.0;

   if(!OrderCalcMargin(orderType, _Symbol, volume, price, margin))
     {
      PrintFormat("ERROR: OrderCalcMargin failed. error=%d", GetLastError());
      return(false);
     }

   const double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);

   if(margin > freeMargin)
     {
      PrintFormat("ERROR: not enough free margin. required=%.2f free=%.2f volume=%.2f",
                  margin, freeMargin, volume);
      return(false);
     }

   return(true);
  }

//+------------------------------------------------------------------+
//| Build normalised SL/TP prices for a market order.                |
//|                                                                  |
//| Ask/Bid orientation                                              |
//|   BUY  : opens at Ask, is closed at Bid -> SL below, TP above.   |
//|   SELL : opens at Bid, is closed at Ask -> SL above, TP below.   |
//|                                                                  |
//| The broker's SYMBOL_TRADE_STOPS_LEVEL is honoured: any distance  |
//| closer than that is pushed out to the minimum legal distance.    |
//| Returns false if a required level cannot be built safely.        |
//+------------------------------------------------------------------+
bool BuildStops(const ENUM_ORDER_TYPE orderType,
                const double         entryPrice,
                double              &slPrice,
                double              &tpPrice)
  {
   slPrice = 0.0;
   tpPrice = 0.0;

   const int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);

//--- keep at least one point of clearance beyond the broker limit --
   const int minDistance = (stopsLevel > 0) ? stopsLevel + 1 : 1;

   int slPoints = InpStopLoss;
   int tpPoints = InpTakeProfit;

   if(slPoints > 0 && slPoints < minDistance)
     {
      PrintFormat("WARNING: StopLoss %d pts is inside the broker stops level (%d). Widening to %d pts.",
                  slPoints, stopsLevel, minDistance);
      slPoints = minDistance;
     }

   if(tpPoints > 0 && tpPoints < minDistance)
     {
      PrintFormat("WARNING: TakeProfit %d pts is inside the broker stops level (%d). Widening to %d pts.",
                  tpPoints, stopsLevel, minDistance);
      tpPoints = minDistance;
     }

   if(orderType == ORDER_TYPE_BUY)
     {
      if(slPoints > 0)
         slPrice = NormalizePrice(entryPrice - slPoints * g_point);
      if(tpPoints > 0)
         tpPrice = NormalizePrice(entryPrice + tpPoints * g_point);

      if(slPoints > 0 && slPrice >= entryPrice)
        {
         Print("ERROR: computed BUY stop loss is not below the entry price. Trade skipped.");
         return(false);
        }
      if(tpPoints > 0 && tpPrice <= entryPrice)
        {
         Print("ERROR: computed BUY take profit is not above the entry price. Trade skipped.");
         return(false);
        }
     }
   else if(orderType == ORDER_TYPE_SELL)
     {
      if(slPoints > 0)
         slPrice = NormalizePrice(entryPrice + slPoints * g_point);
      if(tpPoints > 0)
         tpPrice = NormalizePrice(entryPrice - tpPoints * g_point);

      if(slPoints > 0 && slPrice <= entryPrice)
        {
         Print("ERROR: computed SELL stop loss is not above the entry price. Trade skipped.");
         return(false);
        }
      if(tpPoints > 0 && (tpPrice >= entryPrice || tpPrice <= 0.0))
        {
         Print("ERROR: computed SELL take profit is not below the entry price. Trade skipped.");
         return(false);
        }
     }
   else
     {
      PrintFormat("ERROR: BuildStops called with an unsupported order type %d.", (int)orderType);
      return(false);
     }

   return(true);
  }

//+------------------------------------------------------------------+
//| EXECUTION: send a market order with server-side SL/TP.           |
//| Every failure path is logged with the broker retcode and its     |
//| human-readable description.                                      |
//+------------------------------------------------------------------+
bool OpenPosition(const ENUM_SIGNAL signal)
  {
   const ENUM_ORDER_TYPE orderType =
      (signal == SIGNAL_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

//--- always work from a fresh tick --------------------------------
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
     {
      PrintFormat("ERROR: cannot read the current tick before sending an order. error=%d",
                  GetLastError());
      return(false);
     }

//--- Ask for a BUY, Bid for a SELL --------------------------------
   const double entryPrice = (signal == SIGNAL_BUY) ? tick.ask : tick.bid;

   if(entryPrice <= 0.0)
     {
      Print("ERROR: invalid entry price (zero quote). Trade skipped.");
      return(false);
     }

//--- stops ---------------------------------------------------------
   double slPrice = 0.0, tpPrice = 0.0;
   if(!BuildStops(orderType, entryPrice, slPrice, tpPrice))
      return(false);

//--- volume --------------------------------------------------------
   const double volume = CalculateLotSize(InpStopLoss);

   if(volume <= 0.0)
     {
      Print("ERROR: computed volume is zero. Trade skipped.");
      return(false);
     }

   if(!HasEnoughMargin(orderType, volume, entryPrice))
      return(false);

//--- send ----------------------------------------------------------
   const bool sent = (signal == SIGNAL_BUY)
                     ? trade.Buy(volume, _Symbol, entryPrice, slPrice, tpPrice, InpTradeComment)
                     : trade.Sell(volume, _Symbol, entryPrice, slPrice, tpPrice, InpTradeComment);

   const uint   retcode     = trade.ResultRetcode();
   const string retcodeText = trade.ResultRetcodeDescription();

   if(!sent || (retcode != TRADE_RETCODE_DONE &&
                retcode != TRADE_RETCODE_PLACED &&
                retcode != TRADE_RETCODE_DONE_PARTIAL))
     {
      PrintFormat("ERROR: %s order REJECTED. retcode=%u (%s) lastError=%d "
                  "volume=%.2f price=%s sl=%s tp=%s spread=%.1f pts",
                  (signal == SIGNAL_BUY ? "BUY" : "SELL"),
                  retcode, retcodeText, GetLastError(),
                  volume,
                  DoubleToString(entryPrice, g_digits),
                  DoubleToString(slPrice,    g_digits),
                  DoubleToString(tpPrice,    g_digits),
                  (tick.ask - tick.bid) / g_point);
      return(false);
     }

   PrintFormat("OK: %s %.2f lots filled at %s | sl=%s tp=%s | deal=%I64u order=%I64u retcode=%u (%s)",
               (signal == SIGNAL_BUY ? "BUY" : "SELL"),
               trade.ResultVolume(),
               DoubleToString(trade.ResultPrice(), g_digits),
               DoubleToString(slPrice,             g_digits),
               DoubleToString(tpPrice,             g_digits),
               trade.ResultDeal(), trade.ResultOrder(),
               retcode, retcodeText);

   if(retcode == TRADE_RETCODE_DONE_PARTIAL)
      PrintFormat("WARNING: partial fill. requested=%.2f filled=%.2f", volume, trade.ResultVolume());

   return(true);
  }

//+------------------------------------------------------------------+
//| MAIN TICK HANDLER                                                |
//|                                                                  |
//| Order of checks is deliberate: the cheapest and most restrictive |
//| gates run first so a busy scalping tick stream costs almost      |
//| nothing when we are not allowed to trade anyway.                 |
//+------------------------------------------------------------------+
void OnTick()
  {
//--- 1. terminal / account / symbol permissions --------------------
   if(!IsTradingAllowed())
      return;

//--- 2. never stack positions: one per symbol + magic --------------
   if(HasOpenPosition() || HasPendingOrder())
      return;

//--- 3. session window --------------------------------------------
   if(!IsWithinTradingHours())
      return;

//--- 4. spread guard - the single most important scalping filter ---
   if(!IsSpreadOk())
      return;

//--- 5. evaluate the signal only once per completed bar ------------
   const bool newBar = IsNewBar();

   if(InpOneTradePerBar)
     {
      if(!newBar)
         return;                                       // wait for the next closed bar

      if(g_lastBarTime == g_lastTradeBar)
         return;                                       // already traded on this bar
     }

//--- 6. signal ------------------------------------------------------
   const ENUM_SIGNAL signal = GetSignal();
   if(signal == SIGNAL_NONE)
      return;

//--- 7. re-check the spread right before sending: it can widen      |
//---    between the filter above and the order request.             |
   if(!IsSpreadOk())
      return;

//--- 8. execute -----------------------------------------------------
   if(OpenPosition(signal))
      g_lastTradeBar = g_lastBarTime;                  // block further entries on this bar
  }

//+------------------------------------------------------------------+
//| Trade transaction callback - used purely for diagnostics so the  |
//| journal shows what the server actually did with our requests.    |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
  {
   if(!InpVerboseLog)
      return;

   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   if(trans.symbol != _Symbol)
      return;

   LogInfo(StringFormat("deal added: deal=%I64u order=%I64u type=%d volume=%.2f price=%s",
                        trans.deal, trans.order, (int)trans.deal_type,
                        trans.volume, DoubleToString(trans.price, g_digits)));
  }
//+------------------------------------------------------------------+
