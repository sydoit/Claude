//+------------------------------------------------------------------+
//|                                                 TrendScalper.mq5 |
//|                                                                  |
//|   A trend-following micro-scalper for MetaTrader 5.              |
//|                                                                  |
//|   It waits for a higher-timeframe bias and a same-direction      |
//|   trend on the entry timeframe, then enters on a pullback that   |
//|   resumes or a micro-breakout of the recent range. Size is       |
//|   deliberately small: each entry risks a fraction of a percent   |
//|   and the EA adds further small clips only while price keeps     |
//|   moving in its favour. Stops move to break-even and then trail; |
//|   account-level breakers stop trading for the day when the loss, |
//|   drawdown or losing-streak limits are reached.                  |
//|                                                                  |
//|   Test on a demo account first. Past results in the strategy     |
//|   tester do not predict live results - spread, slippage and      |
//|   execution speed dominate at this timescale.                    |
//+------------------------------------------------------------------+
#property copyright "TrendScalper"
#property link      "https://github.com/sydoit/Claude"
#property version   "1.00"
#property description "Trend-following micro-scalper: small clips, ATR risk control, session and drawdown guards."

#include <TrendScalper/Logger.mqh>
#include <TrendScalper/Config.mqh>
#include <TrendScalper/Utils.mqh>
#include <TrendScalper/SignalEngine.mqh>
#include <TrendScalper/RiskManager.mqh>
#include <TrendScalper/TradeExecutor.mqh>
#include <TrendScalper/Filters.mqh>
#include <TrendScalper/Dashboard.mqh>
#include <TrendScalper/Diagnostics.mqh>

//--- General -------------------------------------------------------
input group "General"
input long              InpMagic              = 770425;      // Magic number (unique per chart)
input string            InpComment            = "TrendScalper"; // Order comment
input ENUM_TS_LOG_LEVEL InpLogLevel           = TS_LOG_INFO; // Log level
input bool              InpTesterVerbose      = false;       // Verbose logging in the tester
input bool              InpShowDashboard      = true;        // Show the on-chart panel
input bool              InpCloseOnDeinit      = false;       // Close positions when the EA is removed

//--- Trend and signal ----------------------------------------------
input group "Trend and signal"
input ENUM_TIMEFRAMES   InpEntryTF            = PERIOD_M1;   // Entry timeframe
input ENUM_TIMEFRAMES   InpTrendTF            = PERIOD_M15;  // Higher timeframe for the bias
input bool              InpUseHtfFilter       = true;        // Require the higher timeframe to agree
input int               InpEmaFast            = 12;          // Fast EMA (entry timeframe)
input int               InpEmaSlow            = 34;          // Slow EMA (entry timeframe)
input int               InpEmaSlopeLookback   = 3;           // Bars used for the EMA slope
input int               InpHtfEmaFast         = 20;          // Fast EMA (higher timeframe)
input int               InpHtfEmaSlow         = 50;          // Slow EMA (higher timeframe)
input int               InpAtrPeriod          = 14;          // ATR period
input int               InpAdxPeriod          = 14;          // ADX period
input double            InpAdxMin             = 20.0;        // Minimum ADX to call it a trend
input int               InpRsiPeriod          = 14;          // RSI period
input double            InpRsiBuyMin          = 45.0;        // Long entries: RSI floor
input double            InpRsiBuyMax          = 78.0;        // Long entries: RSI ceiling
input double            InpRsiSellMin         = 22.0;        // Short entries: RSI floor
input double            InpRsiSellMax         = 55.0;        // Short entries: RSI ceiling

//--- Entry trigger --------------------------------------------------
input group "Entry trigger"
input ENUM_TS_ENTRY_MODE     InpEntryMode     = TS_ENTRY_EITHER;      // Trigger type
input ENUM_TS_SIGNAL_TIMING  InpTiming        = TS_TIMING_EVERY_TICK; // When entries are evaluated
input int               InpBreakoutLookback   = 8;           // Breakout lookback (bars)
input double            InpBreakoutBufferAtr  = 0.05;        // Breakout buffer (ATR multiple)
input double            InpPullbackDepthAtr   = 0.35;        // How close to the EMA a pullback must come (ATR)

//--- Position size --------------------------------------------------
input group "Position size"
input ENUM_TS_LOT_MODE  InpLotMode            = TS_LOT_RISK; // Sizing method
input double            InpFixedLots          = 0.01;        // Fixed volume (fixed mode)
input double            InpRiskPercent        = 0.25;        // Risk per clip (% of equity)
input double            InpMaxLots            = 0.10;        // Hard cap per clip
input double            InpMaxTotalLots       = 0.50;        // Hard cap on total open volume

//--- Stops, targets and exits ---------------------------------------
input group "Stops, targets and exits"
input double            InpStopLossAtr        = 1.20;        // Stop loss (ATR multiple)
input bool              InpUseTakeProfit      = true;        // Use a fixed target
input double            InpTakeProfitAtr      = 1.80;        // Take profit (ATR multiple)
input double            InpBreakEvenAtr       = 0.80;        // Move to break-even after (ATR multiple)
input double            InpBreakEvenOffsetPts = 5.0;         // Break-even offset (points)
input ENUM_TS_TRAIL_MODE InpTrailMode         = TS_TRAIL_ATR;// Trailing method
input double            InpTrailAtr           = 1.00;        // Trailing distance (ATR multiple)
input double            InpTrailStartAtr      = 1.00;        // Start trailing after (ATR multiple)
input double            InpPartialClosePct    = 50.0;        // Partial close size (% of the clip, 0 = off)
input double            InpPartialTriggerAtr  = 1.00;        // Partial close trigger (ATR multiple)
input int               InpMaxHoldSeconds     = 3600;        // Force-close a clip after N seconds (0 = off)
input bool              InpExitOnFlip         = true;        // Close when the trend flips

//--- Stacking -------------------------------------------------------
input group "Stacking (adding into a trend)"
input int               InpMaxPositions       = 4;           // Maximum simultaneous clips
input double            InpAddStepAtr         = 0.75;        // Price must advance this much before adding (ATR)
input bool              InpAddOnlyInProfit    = true;        // Only add while open clips are profitable
input int               InpCooldownSeconds    = 20;          // Minimum seconds between entries

//--- Guards ---------------------------------------------------------
input group "Guards"
input double            InpMaxSpreadPoints    = 20.0;        // Maximum spread (points, 0 = off)
input double            InpMaxSpreadAtr       = 0.25;        // Maximum spread as an ATR fraction (0 = off)
input double            InpDailyLossPercent   = 2.0;         // Stop trading after losing this much today (%)
input double            InpDailyProfitPercent = 3.0;         // Stop trading after making this much today (%, 0 = off)
input double            InpMaxDrawdownPercent = 10.0;        // Stop trading at this equity drawdown (%, 0 = off)
input int               InpMaxConsecLosses    = 4;           // Pause after N losses in a row (0 = off)
input int               InpMaxTradesPerDay    = 40;          // Daily entry cap (0 = off)
input double            InpMinFreeMarginPct   = 30.0;        // Required free margin (% of equity)
input bool              InpFlattenOnHalt      = true;        // Close open clips when a breaker trips
input int               InpMaxSlippagePoints  = 10;          // Maximum slippage (points)
input int               InpOrderRetries       = 3;           // Order attempts before giving up

//--- Schedule -------------------------------------------------------
input group "Schedule (server time)"
input string            InpSessions           = "07:00-11:00,13:00-17:00"; // Trading windows, blank = 24h
input string            InpBlackout           = "";          // Blackout windows (news), blank = none
input bool              InpTradeMonday        = true;        // Trade Monday
input bool              InpTradeTuesday       = true;        // Trade Tuesday
input bool              InpTradeWednesday     = true;        // Trade Wednesday
input bool              InpTradeThursday      = true;        // Trade Thursday
input bool              InpTradeFriday        = true;        // Trade Friday
input int               InpFridayCloseHour    = 20;          // Flatten and stop on Friday at this hour (-1 = off)

//--- Runtime state --------------------------------------------------
SSettings       g_cfg;
CSymbolCtx      g_symbol;
CSignalEngine   g_signals;
CRiskManager    g_risk;
CTradeExecutor  g_exec;
CFilters        g_filters;
CDashboard      g_panel;
datetime        g_last_eval_bar=0;
datetime        g_last_diag_bar=0;
bool            g_sizing_reported=false;
bool            g_ready=false;

//+------------------------------------------------------------------+
void BuildSettings(void)
  {
   g_cfg.magic                  = InpMagic;
   g_cfg.trade_comment          = InpComment;

   g_cfg.entry_tf               = (InpEntryTF==PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)Period() : InpEntryTF;
   g_cfg.trend_tf               = (InpTrendTF==PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)Period() : InpTrendTF;
   g_cfg.ema_fast               = InpEmaFast;
   g_cfg.ema_slow               = InpEmaSlow;
   g_cfg.ema_slope_lookback     = MathMax(1,InpEmaSlopeLookback);
   g_cfg.htf_ema_fast           = InpHtfEmaFast;
   g_cfg.htf_ema_slow           = InpHtfEmaSlow;
   g_cfg.use_htf_filter         = InpUseHtfFilter;
   g_cfg.atr_period             = InpAtrPeriod;
   g_cfg.adx_period             = InpAdxPeriod;
   g_cfg.adx_min                = InpAdxMin;
   g_cfg.rsi_period             = InpRsiPeriod;
   g_cfg.rsi_buy_min            = InpRsiBuyMin;
   g_cfg.rsi_buy_max            = InpRsiBuyMax;
   g_cfg.rsi_sell_min           = InpRsiSellMin;
   g_cfg.rsi_sell_max           = InpRsiSellMax;

   g_cfg.entry_mode             = InpEntryMode;
   g_cfg.timing                 = InpTiming;
   g_cfg.breakout_lookback      = InpBreakoutLookback;
   g_cfg.breakout_buffer_atr    = InpBreakoutBufferAtr;
   g_cfg.pullback_depth_atr     = InpPullbackDepthAtr;

   g_cfg.lot_mode               = InpLotMode;
   g_cfg.fixed_lots             = InpFixedLots;
   g_cfg.risk_percent           = InpRiskPercent;
   g_cfg.max_lots               = InpMaxLots;
   g_cfg.max_total_lots         = InpMaxTotalLots;

   g_cfg.sl_atr                 = InpStopLossAtr;
   g_cfg.use_tp                 = InpUseTakeProfit;
   g_cfg.tp_atr                 = InpTakeProfitAtr;
   g_cfg.be_trigger_atr         = InpBreakEvenAtr;
   g_cfg.be_offset_points       = InpBreakEvenOffsetPts;
   g_cfg.trail_mode             = InpTrailMode;
   g_cfg.trail_atr              = InpTrailAtr;
   g_cfg.trail_start_atr        = InpTrailStartAtr;
   g_cfg.partial_close_pct      = InpPartialClosePct;
   g_cfg.partial_trigger_atr    = InpPartialTriggerAtr;
   g_cfg.max_hold_seconds       = InpMaxHoldSeconds;
   g_cfg.exit_on_flip           = InpExitOnFlip;

   g_cfg.max_positions          = InpMaxPositions;
   g_cfg.add_step_atr           = InpAddStepAtr;
   g_cfg.add_only_in_profit     = InpAddOnlyInProfit;
   g_cfg.cooldown_seconds       = InpCooldownSeconds;

   g_cfg.max_spread_points      = InpMaxSpreadPoints;
   g_cfg.max_spread_atr         = InpMaxSpreadAtr;
   g_cfg.daily_loss_percent     = InpDailyLossPercent;
   g_cfg.daily_profit_percent   = InpDailyProfitPercent;
   g_cfg.max_drawdown_percent   = InpMaxDrawdownPercent;
   g_cfg.max_consecutive_losses = InpMaxConsecLosses;
   g_cfg.max_trades_per_day     = InpMaxTradesPerDay;
   g_cfg.min_free_margin_percent= InpMinFreeMarginPct;
   g_cfg.max_slippage_points    = InpMaxSlippagePoints;
   g_cfg.order_retries          = InpOrderRetries;

   g_cfg.sessions               = InpSessions;
   g_cfg.blackout               = InpBlackout;
   g_cfg.trade_monday           = InpTradeMonday;
   g_cfg.trade_tuesday          = InpTradeTuesday;
   g_cfg.trade_wednesday        = InpTradeWednesday;
   g_cfg.trade_thursday         = InpTradeThursday;
   g_cfg.trade_friday           = InpTradeFriday;
   g_cfg.friday_close_hour      = InpFridayCloseHour;

   g_cfg.show_dashboard         = InpShowDashboard;
  }

//+------------------------------------------------------------------+
//| The volume caps are written in lots, which only means the same    |
//| thing across forex pairs. On a share CFD the broker may quote a   |
//| minimum of 1 with a step of 1, and a 0.10 cap then floors to zero |
//| on every single tick - the EA would simply never trade and never  |
//| say why. Raise an impossible cap to the smallest tradable size    |
//| and say so loudly. The risk budget is untouched: CalcLots still   |
//| refuses any volume whose stop costs more than InpRiskPercent.     |
//+------------------------------------------------------------------+
void AdaptVolumeCapsToSymbol(void)
  {
   double vmin=g_symbol.vol_min;

   if(g_cfg.max_lots>0.0 && g_cfg.max_lots<vmin)
     {
      Log.Report(StringFormat("InpMaxLots (%s) is below this symbol's minimum volume (%s) - "
                              "raised to the minimum, or no order could ever be sized.",
                              g_symbol.LotsToString(g_cfg.max_lots),g_symbol.LotsToString(vmin)));
      g_cfg.max_lots=vmin;
     }

   if(g_cfg.max_total_lots>0.0 && g_cfg.max_total_lots<vmin)
     {
      Log.Report(StringFormat("InpMaxTotalLots (%s) is below this symbol's minimum volume (%s) - "
                              "raised to the minimum.",
                              g_symbol.LotsToString(g_cfg.max_total_lots),g_symbol.LotsToString(vmin)));
      g_cfg.max_total_lots=vmin;
     }

   if(g_cfg.lot_mode==TS_LOT_FIXED && g_cfg.fixed_lots<vmin)
     {
      Log.Report(StringFormat("InpFixedLots (%s) is below this symbol's minimum volume (%s) - "
                              "raised to the minimum.",
                              g_symbol.LotsToString(g_cfg.fixed_lots),g_symbol.LotsToString(vmin)));
      g_cfg.fixed_lots=vmin;
     }
  }

//+------------------------------------------------------------------+
//| Can the configured risk actually buy one minimum lot at this stop |
//| distance, and is the spread small enough to leave an edge? Both   |
//| need a real ATR, so this is printed again on the first tick that  |
//| has one - in the tester OnInit runs before any price exists.      |
//+------------------------------------------------------------------+
void ReportSizingCheck(const double atr)
  {
   if(atr<=0.0)
      return;

   double spread=g_symbol.Spread();

   Log.Report(StringFormat("ATR(%d) on %s: %s   spread %s = %.0f%% of ATR (ceiling %.0f%%)",
                           g_cfg.atr_period,TsTimeframeName(g_cfg.entry_tf),
                           g_symbol.PriceToString(atr),g_symbol.PriceToString(spread),
                           spread/atr*100.0,g_cfg.max_spread_atr*100.0));

   if(g_cfg.max_spread_atr>0.0 && spread>atr*g_cfg.max_spread_atr)
      Log.Report("*** The spread already exceeds InpMaxSpreadAtr. While this holds, "
                 "every entry is filtered out. ***");

   double per_lot=0.0;
   double ask=g_symbol.Ask();
   if(ask>0.0 &&
      OrderCalcProfit(ORDER_TYPE_BUY,_Symbol,1.0,ask,ask-g_cfg.sl_atr*atr,per_lot) &&
      per_lot!=0.0)
     {
      double budget=AccountInfoDouble(ACCOUNT_EQUITY)*g_cfg.risk_percent/100.0;
      double want=budget/MathAbs(per_lot);
      Log.Report(StringFormat("Sizing: %.2f%% of equity = %.2f, the %.2f x ATR stop costs "
                              "%.2f per lot -> wants %s lots (broker minimum %s)",
                              g_cfg.risk_percent,budget,g_cfg.sl_atr,MathAbs(per_lot),
                              DoubleToString(want,4),g_symbol.LotsToString(g_symbol.vol_min)));
      if(want<g_symbol.vol_min)
        {
         Log.Report("*** The risk budget cannot afford one minimum lot at this stop.  ***");
         Log.Report("*** Every entry will be skipped. Raise InpRiskPercent, fund the  ***");
         Log.Report("*** account higher, or trade a lower-priced instrument.          ***");
        }
     }
  }

//+------------------------------------------------------------------+
//| The facts that decide whether this EA can trade this symbol at    |
//| all. Always printed, at any log level, in the tester too.         |
//+------------------------------------------------------------------+
void ReportEnvironment(void)
  {
   Log.Report("===============================================================");
   Log.Report(StringFormat("TrendScalper on %s  entry %s  trend %s",
                           _Symbol,TsTimeframeName(g_cfg.entry_tf),
                           g_cfg.use_htf_filter ? TsTimeframeName(g_cfg.trend_tf) : "off"));
   Log.Report(StringFormat("Volume: min %s  step %s  max %s   |  caps: per clip %s, total %s",
                           g_symbol.LotsToString(g_symbol.vol_min),
                           g_symbol.LotsToString(g_symbol.vol_step),
                           g_symbol.LotsToString(g_symbol.vol_max),
                           g_symbol.LotsToString(g_cfg.max_lots),
                           g_symbol.LotsToString(g_cfg.max_total_lots)));
   Log.Report(StringFormat("Spread now: %.1f points   ceiling: %.1f points",
                           g_symbol.SpreadPoints(),g_cfg.max_spread_points));

   g_filters.ReportSessionOverlap(_Symbol);
   Log.Report("===============================================================");
  }

//+------------------------------------------------------------------+
int OnInit(void)
  {
   Log.Init("TrendScalper",InpLogLevel,InpTesterVerbose);

   BuildSettings();

   if(!TsValidateSettings(g_cfg))
      return(INIT_PARAMETERS_INCORRECT);

   if(!g_symbol.Init(_Symbol))
      return(INIT_FAILED);

   AdaptVolumeCapsToSymbol();

   if(!g_signals.Init(g_cfg,GetPointer(g_symbol)))
      return(INIT_FAILED);

   if(!g_risk.Init(g_cfg,GetPointer(g_symbol)))
      return(INIT_FAILED);

   if(!g_exec.Init(g_cfg,GetPointer(g_symbol),GetPointer(g_risk)))
      return(INIT_FAILED);

   if(!g_filters.Init(g_cfg,GetPointer(g_symbol)))
      return(INIT_PARAMETERS_INCORRECT);

   g_panel.Init(g_cfg.show_dashboard);
   g_last_eval_bar=0;
   g_exec.RefreshBook();

   //--- adopt whatever this magic number already holds, e.g. after a restart,
   //--- and start the entry cooldown from the newest of those positions
   SBook book=g_exec.Book();
   if(book.Count()>0)
     {
      g_filters.NoteEntry(book.newest_entry);
      Log.Info(StringFormat("Adopting %d existing clip(s), %s lots",
                            book.Count(),g_symbol.LotsToString(book.Volume())));
     }

   Diag.Reset();
   g_last_diag_bar=0;
   g_sizing_reported=false;

   ReportEnvironment();

   g_ready=true;
   Log.Info("Initialised - waiting for a trend");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_ready && InpCloseOnDeinit)
      g_exec.CloseAll("EA removed");

   g_panel.Clear();
   g_signals.Release();

   if(g_ready)
      Diag.Report("Why entries were or were not taken (TrendScalper on "+_Symbol+")");

   Log.Info(StringFormat("Stopped (reason %d)",reason));
  }

//+------------------------------------------------------------------+
void OnTick(void)
  {
   if(!g_ready)
      return;

   g_risk.Refresh();
   g_exec.RefreshBook();

   SSignal sig;
   bool    fired=g_signals.Evaluate(sig);

   //--- one-shot pre-flight, now that a real ATR and price exist
   if(!g_sizing_reported && sig.ready && sig.atr>0.0)
     {
      g_sizing_reported=true;
      ReportSizingCheck(sig.atr);
     }

   //--- In new-bar mode an entry is evaluated once per bar, but only
   //--- after the schedule and spread filters have let us through, so a
   //--- momentary wide spread does not burn the whole bar.
   bool    bar_gate=(g_cfg.timing==TS_TIMING_EVERY_TICK) || (sig.bar_time!=g_last_eval_bar);

   datetime now=TimeCurrent();
   string   status="";

   //--- Should everything be flattened right now?
   bool   flatten=false;
   string flatten_reason="";

   if(g_filters.FridayFlatten(now))
     {
      flatten=true;
      flatten_reason="Friday cut-off";
     }
   else
      if(InpFlattenOnHalt && g_risk.IsHalted())
        {
         SRiskState halted=g_risk.State();
         flatten=true;
         flatten_reason=halted.halt_reason;
        }

   //--- Open clips are always managed, even when new entries are blocked.
   g_exec.ManageOpen(sig,flatten,flatten_reason);

   if(flatten)
     {
      status="flat: "+flatten_reason;
      SRiskState risk_flat=g_risk.State();
      SBook      book_flat=g_exec.Book();
      g_panel.Draw(g_cfg,g_symbol,sig,risk_flat,book_flat,status);
      return;
     }

   //--- Entry path. Every branch records a tag so a run that takes no
   //--- trades can still say exactly which gate turned each bar down.
   string reason="";
   string tag="";

   if(!sig.ready)
     {
      status="warming up";
      tag=sig.tag;
     }
   else
      if(!g_risk.TradingAllowed(reason,tag))
         status="blocked: "+reason;
      else
         if(!g_filters.CanEnter(now,sig.atr,reason,tag))
            status="waiting: "+reason;
         else
            if(!bar_gate)
              {
               status=StringFormat("holding for the next %s bar",TsTimeframeName(g_cfg.entry_tf));
               tag="";                       // not a blocker, just timing
              }
            else
              {
               g_last_eval_bar=sig.bar_time;

               if(!fired)
                 {
                  status="no setup: "+sig.reason;
                  tag=sig.tag;
                 }
               else
                  if(g_exec.TryEnter(sig,reason,tag))
                    {
                     g_filters.NoteEntry(now);
                     status=StringFormat("entered %s: %s",TsDirName(sig.direction),sig.reason);
                     Diag.Attempt(tag);
                     tag="";
                    }
                  else
                    {
                     status="skipped: "+reason;
                     Diag.Attempt(tag);
                     Log.Debug("Entry skipped: "+reason);
                     tag="";
                    }
              }

   //--- Sample the blocking reason once per bar, so the tally reads as a
   //--- share of bars rather than of ticks.
   if(sig.bar_time!=g_last_diag_bar)
     {
      g_last_diag_bar=sig.bar_time;
      Diag.Gate(tag=="" ? "reached the entry check" : tag);
     }

   SRiskState risk_now=g_risk.State();
   SBook      book_now=g_exec.Book();
   g_panel.Draw(g_cfg,g_symbol,sig,risk_now,book_now,status);
  }

//+------------------------------------------------------------------+
//| Any completed deal invalidates the cached risk counters.         |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(!g_ready)
      return;

   if(trans.type==TRADE_TRANSACTION_DEAL_ADD && trans.symbol==_Symbol)
      g_risk.OnPositionClosed();
  }
