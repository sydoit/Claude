//+------------------------------------------------------------------+
//|                                                RangeReverter.mq5 |
//|                                                                  |
//|   A mean-reversion range fader for MetaTrader 5.                 |
//|                                                                  |
//|   The companion to TrendScalper, and its opposite. This EA only  |
//|   works when the market is NOT trending: ADX under a ceiling, a  |
//|   flat higher timeframe, and Bollinger bands that are not busy   |
//|   opening up. It then buys the lower band and sells the upper    |
//|   one, targeting the middle band - the mean - and follows that   |
//|   mean as it moves, but only ever inwards.                       |
//|                                                                  |
//|   Mean reversion dies one way: holding a fade through a trend.   |
//|   Three rules exist for that and nothing else - a regime exit    |
//|   that closes when ADX wakes up or price runs past the band, a   |
//|   veto on fading a band that price is walking, and no averaging  |
//|   down by default (InpMaxPositions = 1).                         |
//|                                                                  |
//|   Test on a demo account first. Past results in the strategy     |
//|   tester do not predict live results - spread, slippage and      |
//|   execution speed dominate at this timescale.                    |
//+------------------------------------------------------------------+
#property copyright "RangeReverter"
#property link      "https://github.com/sydoit/Claude"
#property version   "1.00"
#property description "Mean-reversion range fader: buys the lower band, sells the upper, targets the mean, exits when the range breaks."

#include <RangeReverter/Logger.mqh>
#include <RangeReverter/Config.mqh>
#include <RangeReverter/Utils.mqh>
#include <RangeReverter/SignalEngine.mqh>
#include <RangeReverter/RiskManager.mqh>
#include <RangeReverter/TradeExecutor.mqh>
#include <RangeReverter/Filters.mqh>
#include <RangeReverter/Dashboard.mqh>
#include <RangeReverter/Diagnostics.mqh>

//--- General -------------------------------------------------------
input group "General"
input long              InpMagic              = 770426;      // Magic number (unique per chart)
input string            InpComment            = "RangeReverter"; // Order comment
input ENUM_RR_LOG_LEVEL InpLogLevel           = RR_LOG_INFO; // Log level
input bool              InpTesterVerbose      = false;       // Verbose logging in the tester
input bool              InpShowDashboard      = true;        // Show the on-chart panel
input bool              InpCloseOnDeinit      = false;       // Close positions when the EA is removed

//--- Range detection ------------------------------------------------
input group "Range detection"
input ENUM_TIMEFRAMES   InpEntryTF            = PERIOD_M5;   // Entry timeframe
input ENUM_TIMEFRAMES   InpTrendTF            = PERIOD_H1;   // Higher timeframe for the flatness check
input bool              InpUseHtfFilter       = true;        // Require the higher timeframe to be flat
input int               InpBandPeriod         = 20;          // Bollinger period
input double            InpBandDeviation      = 2.0;         // Bollinger deviation
input int               InpAtrPeriod          = 14;          // ATR period
input int               InpAdxPeriod          = 14;          // ADX period
input double            InpAdxMax             = 22.0;        // Stand aside above this ADX (it is trending)
input int               InpHtfEmaFast         = 20;          // Fast EMA (higher timeframe)
input int               InpHtfEmaSlow         = 50;          // Slow EMA (higher timeframe)
input double            InpHtfFlatAtr         = 1.00;        // Max HTF EMA separation, in HTF ATR
input double            InpBandExpansionMax   = 1.60;        // Max band width vs its own average (0 = off)

//--- Edge test ------------------------------------------------------
input group "Edge test (is the trip to the mean worth it?)"
input double            InpMinEdgeAtr         = 0.60;        // Band-to-mean must be at least this x ATR
input double            InpMinEdgeSpreads     = 4.0;         // ...and at least this many spreads (0 = off)
input double            InpMinRewardRisk      = 0.50;        // Minimum target/stop ratio

//--- Entry trigger --------------------------------------------------
input group "Entry trigger"
input ENUM_RR_ENTRY_MODE     InpEntryMode     = RR_ENTRY_EITHER;      // Trigger type
input ENUM_RR_SIGNAL_TIMING  InpTiming        = RR_TIMING_EVERY_TICK; // When entries are evaluated
input int               InpRsiPeriod          = 14;          // RSI period
input double            InpRsiOversold        = 30.0;        // Long fades need RSI at or below this
input double            InpRsiOverbought      = 70.0;        // Short fades need RSI at or above this
input double            InpTouchBufferAtr     = 0.00;        // How far through the band a touch must go (ATR)
input int               InpMaxRideBars        = 1;           // Closes outside the band before it counts as a trend
input double            InpMaxBarAtr          = 2.00;        // Refuse to fade a bar bigger than this x ATR (0 = off)

//--- Position size --------------------------------------------------
input group "Position size"
input ENUM_RR_LOT_MODE  InpLotMode            = RR_LOT_RISK; // Sizing method
input double            InpFixedLots          = 0.01;        // Fixed volume (fixed mode)
input double            InpRiskPercent        = 0.25;        // Risk per clip (% of equity)
input double            InpMaxLots            = 0.10;        // Hard cap per clip
input double            InpMaxTotalLots       = 0.50;        // Hard cap on total open volume

//--- Stops, targets and exits ---------------------------------------
input group "Stops, targets and exits"
input double            InpStopLossAtr        = 1.50;        // Stop loss (ATR multiple)
input double            InpStopBeyondBandAtr  = 0.50;        // ...and at least this far outside the band (0 = off)
input ENUM_RR_TARGET_MODE InpTargetMode       = RR_TARGET_MEAN; // Where the target sits
input double            InpTargetMidFraction  = 0.80;        // Fraction of the trip to the mean to take
input double            InpTakeProfitAtr      = 1.00;        // Target (ATR multiple, ATR mode only)
input bool              InpTrackMean          = true;        // Let the target follow the mean inwards
input double            InpBreakEvenPct       = 60.0;        // Move to break-even at this % of the way (0 = off)
input double            InpBreakEvenOffsetPts = 5.0;         // Break-even offset (points)
input ENUM_RR_TRAIL_MODE InpTrailMode         = RR_TRAIL_NONE;// Trailing method
input double            InpTrailAtr           = 1.00;        // Trailing distance (ATR multiple)
input double            InpTrailStartPct      = 70.0;        // Start trailing at this % of the way
input double            InpPartialClosePct    = 0.0;         // Partial close size (% of the clip, 0 = off)
input double            InpPartialTriggerPct  = 60.0;        // Partial close at this % of the way
input int               InpMaxHoldSeconds     = 7200;        // Force-close a clip after N seconds (0 = off)
input bool              InpExitOnRegimeBreak  = true;        // Close when the range breaks
input double            InpAdxExit            = 30.0;        // ...at this ADX (0 = off)
input double            InpBreakExitAtr       = 0.75;        // ...or this far past the band, in ATR (0 = off)

//--- Stacking -------------------------------------------------------
input group "Stacking (leave at 1 - see the docs)"
input int               InpMaxPositions       = 1;           // Maximum simultaneous clips
input double            InpAddStepAtr         = 1.00;        // Price must extend this much further before adding (ATR)
input int               InpCooldownSeconds    = 60;          // Minimum seconds between entries

//--- Guards ---------------------------------------------------------
input group "Guards"
input double            InpMaxSpreadPoints    = 20.0;        // Maximum spread (points, 0 = off)
input double            InpMaxSpreadAtr       = 0.20;        // Maximum spread as an ATR fraction (0 = off)
input double            InpDailyLossPercent   = 2.0;         // Stop trading after losing this much today (%)
input double            InpDailyProfitPercent = 3.0;         // Stop trading after making this much today (%, 0 = off)
input double            InpMaxDrawdownPercent = 10.0;        // Stop trading at this equity drawdown (%, 0 = off)
input int               InpMaxConsecLosses    = 4;           // Pause after N losses in a row (0 = off)
input int               InpMaxTradesPerDay    = 20;          // Daily entry cap (0 = off)
input double            InpMinFreeMarginPct   = 30.0;        // Required free margin (% of equity)
input bool              InpFlattenOnHalt      = true;        // Close open clips when a breaker trips
input int               InpMaxSlippagePoints  = 10;          // Maximum slippage (points)
input int               InpOrderRetries       = 3;           // Order attempts before giving up

//--- Schedule -------------------------------------------------------
input group "Schedule (server time)"
input string            InpSessions           = "";          // Trading windows, blank = 24h
input string            InpBlackout           = "";          // Blackout windows (news), blank = none
input bool              InpTradeMonday        = true;        // Trade Monday
input bool              InpTradeTuesday       = true;        // Trade Tuesday
input bool              InpTradeWednesday     = true;        // Trade Wednesday
input bool              InpTradeThursday      = true;        // Trade Thursday
input bool              InpTradeFriday        = true;        // Trade Friday
input int               InpFridayCloseHour    = 20;          // Flatten and stop on Friday at this hour (-1 = off)

//--- Runtime state --------------------------------------------------
SRrSettings      g_cfg;
CRrSymbolCtx     g_symbol;
CRrSignalEngine  g_signals;
CRrRiskManager   g_risk;
CRrTradeExecutor g_exec;
CRrFilters       g_filters;
CRrDashboard     g_panel;
datetime         g_last_eval_bar=0;
datetime         g_last_diag_bar=0;
bool             g_sizing_reported=false;
bool             g_ready=false;

//+------------------------------------------------------------------+
void BuildSettings(void)
  {
   g_cfg.magic                  = InpMagic;
   g_cfg.trade_comment          = InpComment;

   g_cfg.entry_tf               = (InpEntryTF==PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)Period() : InpEntryTF;
   g_cfg.trend_tf               = (InpTrendTF==PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)Period() : InpTrendTF;
   g_cfg.band_period            = InpBandPeriod;
   g_cfg.band_deviation         = InpBandDeviation;
   g_cfg.atr_period             = InpAtrPeriod;
   g_cfg.adx_period             = InpAdxPeriod;
   g_cfg.adx_max                = InpAdxMax;
   g_cfg.adx_exit               = InpAdxExit;
   g_cfg.rsi_period             = InpRsiPeriod;
   g_cfg.rsi_oversold           = InpRsiOversold;
   g_cfg.rsi_overbought         = InpRsiOverbought;

   g_cfg.use_htf_filter         = InpUseHtfFilter;
   g_cfg.htf_ema_fast           = InpHtfEmaFast;
   g_cfg.htf_ema_slow           = InpHtfEmaSlow;
   g_cfg.htf_flat_atr           = InpHtfFlatAtr;

   g_cfg.min_edge_atr           = InpMinEdgeAtr;
   g_cfg.min_edge_spreads       = InpMinEdgeSpreads;
   g_cfg.min_reward_risk        = InpMinRewardRisk;

   g_cfg.entry_mode             = InpEntryMode;
   g_cfg.timing                 = InpTiming;
   g_cfg.touch_buffer_atr       = InpTouchBufferAtr;
   g_cfg.max_ride_bars          = InpMaxRideBars;
   g_cfg.max_bar_atr            = InpMaxBarAtr;
   g_cfg.band_expansion_max     = InpBandExpansionMax;

   g_cfg.lot_mode               = InpLotMode;
   g_cfg.fixed_lots             = InpFixedLots;
   g_cfg.risk_percent           = InpRiskPercent;
   g_cfg.max_lots               = InpMaxLots;
   g_cfg.max_total_lots         = InpMaxTotalLots;

   g_cfg.sl_atr                 = InpStopLossAtr;
   g_cfg.sl_beyond_band_atr     = InpStopBeyondBandAtr;
   g_cfg.target_mode            = InpTargetMode;
   g_cfg.target_mid_fraction    = InpTargetMidFraction;
   g_cfg.tp_atr                 = InpTakeProfitAtr;
   g_cfg.track_mean             = InpTrackMean;
   g_cfg.be_trigger_pct         = InpBreakEvenPct;
   g_cfg.be_offset_points       = InpBreakEvenOffsetPts;
   g_cfg.trail_mode             = InpTrailMode;
   g_cfg.trail_atr              = InpTrailAtr;
   g_cfg.trail_start_pct        = InpTrailStartPct;
   g_cfg.partial_close_pct      = InpPartialClosePct;
   g_cfg.partial_trigger_pct    = InpPartialTriggerPct;
   g_cfg.max_hold_seconds       = InpMaxHoldSeconds;
   g_cfg.exit_on_regime_break   = InpExitOnRegimeBreak;
   g_cfg.break_exit_atr         = InpBreakExitAtr;

   g_cfg.max_positions          = InpMaxPositions;
   g_cfg.add_step_atr           = InpAddStepAtr;
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
      RLog.Report(StringFormat("InpMaxLots (%s) is below this symbol's minimum volume (%s) - "
                               "raised to the minimum, or no order could ever be sized.",
                               g_symbol.LotsToString(g_cfg.max_lots),g_symbol.LotsToString(vmin)));
      g_cfg.max_lots=vmin;
     }

   if(g_cfg.max_total_lots>0.0 && g_cfg.max_total_lots<vmin)
     {
      RLog.Report(StringFormat("InpMaxTotalLots (%s) is below this symbol's minimum volume (%s) - "
                               "raised to the minimum.",
                               g_symbol.LotsToString(g_cfg.max_total_lots),g_symbol.LotsToString(vmin)));
      g_cfg.max_total_lots=vmin;
     }

   if(g_cfg.lot_mode==RR_LOT_FIXED && g_cfg.fixed_lots<vmin)
     {
      RLog.Report(StringFormat("InpFixedLots (%s) is below this symbol's minimum volume (%s) - "
                               "raised to the minimum.",
                               g_symbol.LotsToString(g_cfg.fixed_lots),g_symbol.LotsToString(vmin)));
      g_cfg.fixed_lots=vmin;
     }
  }

//+------------------------------------------------------------------+
//| Can the configured risk buy one minimum lot at this stop, and is  |
//| the band-to-mean trip worth more than the round-trip cost? Both   |
//| need a real ATR and a real band, so this is printed on the first  |
//| tick that has them - in the tester OnInit runs before any price.  |
//+------------------------------------------------------------------+
void ReportSizingCheck(const SRrSignal &sig)
  {
   double atr=sig.atr;
   if(atr<=0.0)
      return;

   double spread=g_symbol.Spread();

   RLog.Report(StringFormat("ATR(%d) on %s: %s   spread %s = %.0f%% of ATR (ceiling %.0f%%)",
                            g_cfg.atr_period,RrTimeframeName(g_cfg.entry_tf),
                            g_symbol.PriceToString(atr),g_symbol.PriceToString(spread),
                            spread/atr*100.0,g_cfg.max_spread_atr*100.0));

   if(g_cfg.max_spread_atr>0.0 && spread>atr*g_cfg.max_spread_atr)
      RLog.Report("*** The spread already exceeds InpMaxSpreadAtr. While this holds, "
                  "every entry is filtered out. ***");

   //--- the economic test that decides whether this symbol is fadeable at all
   if(sig.edge>0.0)
     {
      RLog.Report(StringFormat("Edge now: band-to-mean %s = %.2f x ATR = %.1f spreads "
                               "(floors %.2f ATR / %.1f spreads)",
                               g_symbol.PriceToString(sig.edge),sig.edge/atr,
                               spread>0.0 ? sig.edge/spread : 0.0,
                               g_cfg.min_edge_atr,g_cfg.min_edge_spreads));
      if(g_cfg.min_edge_spreads>0.0 && spread>0.0 && sig.edge<g_cfg.min_edge_spreads*spread)
        {
         RLog.Report("*** The trip back to the mean does not cover the spread floor.   ***");
         RLog.Report("*** Every entry will be skipped while that holds. Use a slower   ***");
         RLog.Report("*** InpEntryTF, or accept this symbol cannot be faded here.      ***");
        }
     }

   double per_lot=0.0;
   double ask=g_symbol.Ask();
   if(ask>0.0 &&
      OrderCalcProfit(ORDER_TYPE_BUY,_Symbol,1.0,ask,ask-g_cfg.sl_atr*atr,per_lot) &&
      per_lot!=0.0)
     {
      double budget=AccountInfoDouble(ACCOUNT_EQUITY)*g_cfg.risk_percent/100.0;
      double want=budget/MathAbs(per_lot);
      RLog.Report(StringFormat("Sizing: %.2f%% of equity = %.2f, the %.2f x ATR stop costs "
                               "%.2f per lot -> wants %s lots (broker minimum %s)",
                               g_cfg.risk_percent,budget,g_cfg.sl_atr,MathAbs(per_lot),
                               DoubleToString(want,4),g_symbol.LotsToString(g_symbol.vol_min)));
      if(want<g_symbol.vol_min)
        {
         RLog.Report("*** The risk budget cannot afford one minimum lot at this stop.  ***");
         RLog.Report("*** Every entry will be skipped. Raise InpRiskPercent, fund the  ***");
         RLog.Report("*** account higher, or trade a lower-priced instrument.          ***");
        }
     }
  }

//+------------------------------------------------------------------+
//| The facts that decide whether this EA can trade this symbol at    |
//| all. Always printed, at any log level, in the tester too.         |
//+------------------------------------------------------------------+
void ReportEnvironment(void)
  {
   RLog.Report("===============================================================");
   RLog.Report("RangeReverter build 1.00 (diagnostics enabled)");
   RLog.Report(StringFormat("RangeReverter on %s  entry %s  flatness %s",
                            _Symbol,RrTimeframeName(g_cfg.entry_tf),
                            g_cfg.use_htf_filter ? RrTimeframeName(g_cfg.trend_tf) : "off"));
   RLog.Report(StringFormat("Range gate: ADX <= %.1f, bands %d x %.2f, RSI %.0f/%.0f",
                            g_cfg.adx_max,g_cfg.band_period,g_cfg.band_deviation,
                            g_cfg.rsi_oversold,g_cfg.rsi_overbought));
   RLog.Report(StringFormat("Volume: min %s  step %s  max %s   |  caps: per clip %s, total %s",
                            g_symbol.LotsToString(g_symbol.vol_min),
                            g_symbol.LotsToString(g_symbol.vol_step),
                            g_symbol.LotsToString(g_symbol.vol_max),
                            g_symbol.LotsToString(g_cfg.max_lots),
                            g_symbol.LotsToString(g_cfg.max_total_lots)));
   RLog.Report(StringFormat("Spread now: %.1f points   ceiling: %.1f points",
                            g_symbol.SpreadPoints(),g_cfg.max_spread_points));
   if(g_cfg.max_positions>1)
      RLog.Report(StringFormat("InpMaxPositions is %d - this EA will average down. "
                               "1 is the tested default.",g_cfg.max_positions));

   g_filters.ReportSessionOverlap(_Symbol);
   RLog.Report("===============================================================");
  }

//+------------------------------------------------------------------+
int OnInit(void)
  {
   RLog.Init("RangeReverter",InpLogLevel,InpTesterVerbose);

   BuildSettings();

   if(!RrValidateSettings(g_cfg))
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
   SRrBook book=g_exec.Book();
   if(book.Count()>0)
     {
      g_filters.NoteEntry(book.newest_entry);
      RLog.Info(StringFormat("Adopting %d existing clip(s), %s lots",
                             book.Count(),g_symbol.LotsToString(book.Volume())));
     }

   RDiag.Reset();
   g_last_diag_bar=0;
   g_sizing_reported=false;

   ReportEnvironment();

   g_ready=true;
   RLog.Info("Initialised - waiting for a range");
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
      RDiag.Report("Why fades were or were not taken (RangeReverter on "+_Symbol+")");

   RLog.Info(StringFormat("Stopped (reason %d)",reason));
  }

//+------------------------------------------------------------------+
void OnTick(void)
  {
   if(!g_ready)
      return;

   RDiag.Tick(TimeCurrent());

   g_risk.Refresh();
   g_exec.RefreshBook();

   SRrSignal sig;
   bool      fired=g_signals.Evaluate(sig);

   //--- one-shot pre-flight, now that a real ATR, band and price exist
   if(!g_sizing_reported && sig.ready && sig.atr>0.0)
     {
      g_sizing_reported=true;
      ReportSizingCheck(sig);
     }

   //--- In new-bar mode an entry is evaluated once per bar, but only
   //--- after the schedule and spread filters have let us through, so a
   //--- momentary wide spread does not burn the whole bar.
   bool     bar_gate=(g_cfg.timing==RR_TIMING_EVERY_TICK) || (sig.bar_time!=g_last_eval_bar);

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
         SRrRiskState halted=g_risk.State();
         flatten=true;
         flatten_reason=halted.halt_reason;
        }

   //--- Open fades are always managed, even when new entries are blocked.
   //--- The regime exit lives in here, so it keeps working after a breaker
   //--- has stopped the EA from opening anything new.
   g_exec.ManageOpen(sig,flatten,flatten_reason);

   if(flatten)
     {
      status="flat: "+flatten_reason;
      SRrRiskState risk_flat=g_risk.State();
      SRrBook      book_flat=g_exec.Book();
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
               status=StringFormat("holding for the next %s bar",RrTimeframeName(g_cfg.entry_tf));
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
                     status=StringFormat("faded %s: %s",RrDirName(sig.direction),sig.reason);
                     RDiag.Attempt(tag);
                     tag="";
                    }
                  else
                    {
                     status="skipped: "+reason;
                     RDiag.Attempt(tag);
                     RLog.Debug("Entry skipped: "+reason);
                     tag="";
                    }
              }

   //--- Sample the blocking reason once per bar, so the tally reads as a
   //--- share of bars rather than of ticks. With no usable data there is
   //--- no bar to key on, so those ticks are counted separately - that
   //--- distinction is what tells a history problem from a quiet market.
   if(!sig.ready)
      RDiag.Warmup(sig.tag);
   else
      if(sig.bar_time!=g_last_diag_bar)
        {
         g_last_diag_bar=sig.bar_time;
         RDiag.Gate(tag=="" ? "reached the entry check" : tag);
        }

   SRrRiskState risk_now=g_risk.State();
   SRrBook      book_now=g_exec.Book();
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
