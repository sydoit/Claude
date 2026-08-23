//+------------------------------------------------------------------+
//|                                                       Config.mqh |
//|   Enumerations and the settings block shared by every module.    |
//+------------------------------------------------------------------+
#ifndef RR_CONFIG_MQH
#define RR_CONFIG_MQH

#include <RangeReverter/Logger.mqh>

//--- How an entry is triggered once the range filters agree.
enum ENUM_RR_ENTRY_MODE
  {
   RR_ENTRY_TOUCH  = 0,   // Fade the moment price trades through the band
   RR_ENTRY_REJECT = 1,   // Wait for a bar to pierce the band and close back inside
   RR_ENTRY_EITHER = 2    // Whichever fires first
  };

//--- How trade size is decided.
enum ENUM_RR_LOT_MODE
  {
   RR_LOT_FIXED = 0,      // Fixed volume
   RR_LOT_RISK  = 1       // Percent of equity risked to the stop
  };

//--- Where the profit target sits.
enum ENUM_RR_TARGET_MODE
  {
   RR_TARGET_MEAN = 0,    // A fraction of the way back to the middle band
   RR_TARGET_ATR  = 1     // A fixed ATR multiple from entry
  };

//--- How the stop is dragged behind price.
enum ENUM_RR_TRAIL_MODE
  {
   RR_TRAIL_NONE = 0,     // No trailing
   RR_TRAIL_ATR  = 1      // Fixed ATR distance behind price
  };

//--- When entry signals are evaluated.
enum ENUM_RR_SIGNAL_TIMING
  {
   RR_TIMING_EVERY_TICK = 0,   // Every tick (fastest, more trades)
   RR_TIMING_NEW_BAR    = 1    // Once per closed bar (calmer, fewer trades)
  };

//+------------------------------------------------------------------+
//| Plain settings carrier. Populated from the EA inputs in OnInit   |
//| and then passed by reference to each module, so no module has to |
//| reach for globals.                                               |
//+------------------------------------------------------------------+
struct SRrSettings
  {
   //--- identity
   long              magic;
   string            trade_comment;

   //--- timeframes and indicators
   ENUM_TIMEFRAMES   entry_tf;
   ENUM_TIMEFRAMES   trend_tf;
   int               band_period;
   double            band_deviation;
   int               atr_period;
   int               adx_period;
   double            adx_max;          // above this the market is trending: stand aside
   double            adx_exit;         // above this, close what is already open
   int               rsi_period;
   double            rsi_oversold;     // long fades need RSI at or below this
   double            rsi_overbought;   // short fades need RSI at or above this

   //--- higher-timeframe flatness filter
   bool              use_htf_filter;
   int               htf_ema_fast;
   int               htf_ema_slow;
   double            htf_flat_atr;     // |fast-slow| must stay under this x HTF ATR

   //--- the edge test: is the trip back to the mean worth taking?
   double            min_edge_atr;     // band-to-mean distance, in ATR
   double            min_edge_spreads; // ...and in multiples of the current spread
   double            min_reward_risk;  // target distance / stop distance

   //--- entry trigger
   ENUM_RR_ENTRY_MODE entry_mode;
   ENUM_RR_SIGNAL_TIMING timing;
   double            touch_buffer_atr; // how far through the band a touch must go
   int               max_ride_bars;    // consecutive closes outside the band before we call it a trend
   double            max_bar_atr;      // refuse to fade a bar larger than this x ATR
   double            band_expansion_max; // band width vs its own average; 0 = off

   //--- sizing
   ENUM_RR_LOT_MODE  lot_mode;
   double            fixed_lots;
   double            risk_percent;
   double            max_lots;
   double            max_total_lots;

   //--- stops, targets and exits
   double            sl_atr;              // stop distance from entry, in ATR
   double            sl_beyond_band_atr;  // ...and at least this far outside the band (0 = off)
   ENUM_RR_TARGET_MODE target_mode;
   double            target_mid_fraction; // how much of the band-to-mean trip to take
   double            tp_atr;              // target in ATR, when target_mode is ATR
   bool              track_mean;          // follow the moving mean, but only closer
   double            be_trigger_pct;      // move to break-even at this % of the way to target
   double            be_offset_points;
   ENUM_RR_TRAIL_MODE trail_mode;
   double            trail_atr;
   double            trail_start_pct;     // start trailing at this % of the way to target
   double            partial_close_pct;
   double            partial_trigger_pct; // ...at this % of the way to target
   int               max_hold_seconds;
   bool              exit_on_regime_break;
   double            break_exit_atr;      // close if price runs this far past the band against us

   //--- position stacking (off by default: adding here is averaging down)
   int               max_positions;
   double            add_step_atr;
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
bool RrValidateSettings(const SRrSettings &s)
  {
   bool ok=true;

   if(s.band_period<2)
     {
      RLog.Error("Band period must be >= 2");
      ok=false;
     }
   if(s.band_deviation<=0.0)
     {
      RLog.Error("Band deviation must be > 0");
      ok=false;
     }
   if(s.atr_period<1 || s.adx_period<1 || s.rsi_period<1)
     {
      RLog.Error("Indicator periods must be >= 1");
      ok=false;
     }
   if(s.use_htf_filter && s.htf_ema_fast>=s.htf_ema_slow)
     {
      RLog.Error("Higher-timeframe fast EMA must be shorter than its slow EMA");
      ok=false;
     }
   if(s.rsi_oversold>=s.rsi_overbought)
     {
      RLog.Error(StringFormat("RSI oversold (%.1f) must be below RSI overbought (%.1f)",
                              s.rsi_oversold,s.rsi_overbought));
      ok=false;
     }
   if(s.adx_max<=0.0)
     {
      RLog.Error("ADX ceiling must be > 0 - it is what keeps this EA out of trends");
      ok=false;
     }
   if(s.sl_atr<=0.0)
     {
      RLog.Error("Stop-loss ATR multiple must be > 0 - the EA never trades without a stop");
      ok=false;
     }
   if(s.target_mode==RR_TARGET_MEAN && (s.target_mid_fraction<=0.0 || s.target_mid_fraction>1.5))
     {
      RLog.Error("Target fraction must be within (0, 1.5] - 1.0 is the middle band itself");
      ok=false;
     }
   if(s.target_mode==RR_TARGET_ATR && s.tp_atr<=0.0)
     {
      RLog.Error("Take-profit ATR multiple must be > 0 in ATR target mode");
      ok=false;
     }
   if(s.lot_mode==RR_LOT_RISK && (s.risk_percent<=0.0 || s.risk_percent>5.0))
     {
      RLog.Error("Risk percent must be within (0, 5] - this EA is built for small clips");
      ok=false;
     }
   if(s.lot_mode==RR_LOT_FIXED && s.fixed_lots<=0.0)
     {
      RLog.Error("Fixed volume must be > 0");
      ok=false;
     }
   if(s.max_positions<1)
     {
      RLog.Error("Max positions must be >= 1");
      ok=false;
     }
   if(s.partial_close_pct<0.0 || s.partial_close_pct>=100.0)
     {
      RLog.Error("Partial close percent must be within [0, 100)");
      ok=false;
     }
   if(s.max_ride_bars<0)
     {
      RLog.Error("Max ride bars must be >= 0");
      ok=false;
     }

   //--- The one that deserves shouting about: this is a mean reverter, and
   //--- every extra clip is opened further into a move that has already gone
   //--- against the first one. That is averaging down, by definition.
   if(s.max_positions>1)
     {
      RLog.Warn(StringFormat("InpMaxPositions is %d. Extra clips are added further into "
                             "the extreme, which IS averaging down - the failure mode that "
                             "kills mean-reversion systems. Keep it at 1 unless you have "
                             "tested the drawdown this produces.",s.max_positions));
      if(s.add_step_atr<=0.0)
        {
         RLog.Error("With InpMaxPositions > 1 the add step must be > 0, otherwise clips "
                    "pile onto the same price");
         ok=false;
        }
     }

   if(s.adx_exit>0.0 && s.adx_exit<s.adx_max)
      RLog.Warn("InpAdxExit is below InpAdxMax - a fresh entry could be closed by the "
                "regime exit on the very next tick");
   if(s.min_edge_spreads<=0.0)
      RLog.Warn("No spread-multiple edge test - the EA may fade trips to the mean that "
                "cannot cover their own round-trip cost");
   if(s.trend_tf!=PERIOD_CURRENT && s.entry_tf!=PERIOD_CURRENT &&
      PeriodSeconds(s.trend_tf)<PeriodSeconds(s.entry_tf))
      RLog.Warn("Trend timeframe is faster than the entry timeframe - the flatness filter "
                "will add noise");
   if(s.max_spread_points<=0.0 && s.max_spread_atr<=0.0)
      RLog.Warn("No spread ceiling configured - fading a range on a wide-spread account bleeds cost");
   if(s.daily_loss_percent<=0.0)
      RLog.Warn("Daily loss limit disabled - consider setting one before trading live");
   if(!s.exit_on_regime_break)
      RLog.Warn("InpExitOnRegimeBreak is off. A mean reverter with no regime exit holds "
                "its fade all the way through a breakout");

   return(ok);
  }

#endif // RR_CONFIG_MQH
