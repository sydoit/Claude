//+------------------------------------------------------------------+
//|                                                       Config.mqh |
//|   Enumerations and the settings block shared by every module.    |
//+------------------------------------------------------------------+
#ifndef TS_CONFIG_MQH
#define TS_CONFIG_MQH

#include <TrendScalper/Logger.mqh>

//--- How an entry is triggered once the trend filters agree.
enum ENUM_TS_ENTRY_MODE
  {
   TS_ENTRY_PULLBACK = 0,   // Pullback to the fast EMA, then resume
   TS_ENTRY_BREAKOUT = 1,   // Micro-breakout of the recent range
   TS_ENTRY_EITHER   = 2    // Whichever fires first
  };

//--- How trade size is decided.
enum ENUM_TS_LOT_MODE
  {
   TS_LOT_FIXED = 0,        // Fixed volume
   TS_LOT_RISK  = 1         // Percent of equity risked to the stop
  };

//--- How the stop is dragged behind price.
enum ENUM_TS_TRAIL_MODE
  {
   TS_TRAIL_NONE = 0,       // No trailing
   TS_TRAIL_ATR  = 1,       // Fixed ATR distance behind price
   TS_TRAIL_EMA  = 2        // Behind the fast EMA
  };

//--- When entry signals are evaluated.
enum ENUM_TS_SIGNAL_TIMING
  {
   TS_TIMING_EVERY_TICK = 0,   // Every tick (fastest, more trades)
   TS_TIMING_NEW_BAR    = 1    // Once per closed bar (calmer, fewer trades)
  };

//+------------------------------------------------------------------+
//| Plain settings carrier. Populated from the EA inputs in OnInit   |
//| and then passed by reference to each module, so no module has to |
//| reach for globals.                                               |
//+------------------------------------------------------------------+
struct SSettings
  {
   //--- identity
   long              magic;
   string            trade_comment;

   //--- timeframes and indicators
   ENUM_TIMEFRAMES   entry_tf;
   ENUM_TIMEFRAMES   trend_tf;
   int               ema_fast;
   int               ema_slow;
   int               ema_slope_lookback;
   int               htf_ema_fast;
   int               htf_ema_slow;
   bool              use_htf_filter;
   int               atr_period;
   int               adx_period;
   double            adx_min;
   int               rsi_period;
   double            rsi_buy_min;
   double            rsi_buy_max;
   double            rsi_sell_min;
   double            rsi_sell_max;

   //--- entry trigger
   ENUM_TS_ENTRY_MODE entry_mode;
   int               breakout_lookback;
   double            breakout_buffer_atr;
   double            pullback_depth_atr;
   ENUM_TS_SIGNAL_TIMING timing;

   //--- sizing
   ENUM_TS_LOT_MODE  lot_mode;
   double            fixed_lots;
   double            risk_percent;
   double            max_lots;
   double            max_total_lots;

   //--- stops and targets (all in ATR multiples)
   double            sl_atr;
   double            tp_atr;
   bool              use_tp;
   double            be_trigger_atr;
   double            be_offset_points;
   ENUM_TS_TRAIL_MODE trail_mode;
   double            trail_atr;
   double            trail_start_atr;
   double            partial_close_pct;
   double            partial_trigger_atr;
   int               max_hold_seconds;
   bool              exit_on_flip;

   //--- position stacking (the "small clips, added into a trend" behaviour)
   int               max_positions;
   double            add_step_atr;
   bool              add_only_in_profit;
   int               cooldown_seconds;

   //--- guards
   double            max_spread_points;
   double            max_spread_atr;
   double            daily_loss_percent;
   double            daily_profit_percent;
   double            max_drawdown_percent;
   int               max_consecutive_losses;
   int               max_trades_per_day;
   double            min_free_margin_percent;
   int               max_slippage_points;
   int               order_retries;

   //--- schedule
   string            sessions;
   string            blackout;
   bool              trade_monday;
   bool              trade_tuesday;
   bool              trade_wednesday;
   bool              trade_thursday;
   bool              trade_friday;
   int               friday_close_hour;   // -1 disables

   //--- misc
   bool              show_dashboard;
  };

//+------------------------------------------------------------------+
//| Sanity-checks the settings. Anything that would silently produce |
//| nonsense trades is an error; anything merely suspicious is a     |
//| warning so the EA still starts.                                  |
//+------------------------------------------------------------------+
bool TsValidateSettings(const SSettings &s)
  {
   bool ok=true;

   if(s.ema_fast<1 || s.ema_slow<1)
     {
      Log.Error("EMA periods must be >= 1");
      ok=false;
     }
   if(s.ema_fast>=s.ema_slow)
     {
      Log.Error(StringFormat("Fast EMA (%d) must be shorter than slow EMA (%d)",s.ema_fast,s.ema_slow));
      ok=false;
     }
   if(s.use_htf_filter && s.htf_ema_fast>=s.htf_ema_slow)
     {
      Log.Error("Higher-timeframe fast EMA must be shorter than its slow EMA");
      ok=false;
     }
   if(s.atr_period<1 || s.adx_period<1 || s.rsi_period<1)
     {
      Log.Error("Indicator periods must be >= 1");
      ok=false;
     }
   if(s.sl_atr<=0.0)
     {
      Log.Error("Stop-loss ATR multiple must be > 0 - the EA never trades without a stop");
      ok=false;
     }
   if(s.use_tp && s.tp_atr<=0.0)
     {
      Log.Error("Take-profit ATR multiple must be > 0 when the target is enabled");
      ok=false;
     }
   if(s.lot_mode==TS_LOT_RISK && (s.risk_percent<=0.0 || s.risk_percent>5.0))
     {
      Log.Error("Risk percent must be within (0, 5] - this EA is built for small clips");
      ok=false;
     }
   if(s.lot_mode==TS_LOT_FIXED && s.fixed_lots<=0.0)
     {
      Log.Error("Fixed volume must be > 0");
      ok=false;
     }
   if(s.max_positions<1)
     {
      Log.Error("Max positions must be >= 1");
      ok=false;
     }
   if(s.partial_close_pct<0.0 || s.partial_close_pct>=100.0)
     {
      Log.Error("Partial close percent must be within [0, 100)");
      ok=false;
     }
   if(s.entry_mode!=TS_ENTRY_PULLBACK && s.breakout_lookback<2)
     {
      Log.Error("Breakout lookback must be >= 2 bars");
      ok=false;
     }
   if(s.trend_tf!=PERIOD_CURRENT && s.entry_tf!=PERIOD_CURRENT &&
      PeriodSeconds(s.trend_tf)<PeriodSeconds(s.entry_tf))
      Log.Warn("Trend timeframe is faster than the entry timeframe - the bias filter will add noise");
   if(s.use_tp && s.tp_atr<s.sl_atr*0.5)
      Log.Warn("Take-profit is less than half the stop distance - the strategy needs a high hit rate to break even");
   if(s.max_spread_points<=0.0 && s.max_spread_atr<=0.0)
      Log.Warn("No spread ceiling configured - a fast scalper on a wide-spread account bleeds cost");
   if(s.cooldown_seconds<=0 && s.timing==TS_TIMING_EVERY_TICK)
      Log.Warn("Tick-timed entries with no cooldown can stack positions extremely fast");
   if(s.daily_loss_percent<=0.0)
      Log.Warn("Daily loss limit disabled - consider setting one before trading live");

   return(ok);
  }

#endif // TS_CONFIG_MQH
