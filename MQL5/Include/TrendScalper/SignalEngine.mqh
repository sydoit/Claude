//+------------------------------------------------------------------+
//|                                                 SignalEngine.mqh |
//|   Trend detection and entry triggers.                            |
//|                                                                  |
//|   Direction comes from three agreeing layers:                    |
//|     1. higher-timeframe EMA bias   (where the market is going)   |
//|     2. entry-timeframe EMA stack + slope, gated by ADX strength  |
//|     3. a trigger - either a pullback that resumes, or a micro    |
//|        breakout of the last N bars                               |
//|   RSI is used only to veto entries into an already-stretched     |
//|   move. Triggers are checked against the live price so the EA    |
//|   can act inside the bar rather than waiting for the close.      |
//+------------------------------------------------------------------+
#ifndef TS_SIGNALENGINE_MQH
#define TS_SIGNALENGINE_MQH

#include <TrendScalper/Config.mqh>
#include <TrendScalper/Utils.mqh>

//+------------------------------------------------------------------+
struct SSignal
  {
   int               direction;     // +1 buy, -1 sell, 0 stand aside
   int               bias;          // higher-timeframe direction
   int               trend;         // entry-timeframe direction
   double            atr;
   double            adx;
   double            rsi;
   double            ema_fast;
   double            ema_slow;
   datetime          bar_time;
   string            reason;        // why we did / did not fire
   bool              ready;         // indicator data usable this tick
  };

//+------------------------------------------------------------------+
class CSignalEngine
  {
private:
   SSettings         m_cfg;
   CSymbolCtx       *m_sym;

   int               m_h_ema_fast;
   int               m_h_ema_slow;
   int               m_h_atr;
   int               m_h_adx;
   int               m_h_rsi;
   int               m_h_htf_fast;
   int               m_h_htf_slow;

   int               m_depth;        // bars to pull each refresh

   double            m_ema_fast[];
   double            m_ema_slow[];
   double            m_atr[];
   double            m_adx[];
   double            m_rsi[];
   double            m_htf_fast[];
   double            m_htf_slow[];
   MqlRates          m_rates[];

   bool              Pull(void);
   bool              HandleReady(const int handle,const ENUM_TIMEFRAMES tf) const;
   int               EvaluateBias(void) const;
   int               EvaluateTrend(void) const;
   bool              RsiAllows(const int dir) const;
   bool              TriggerFires(const int dir,string &why) const;
   double            HighestHigh(const int from,const int count) const;
   double            LowestLow(const int from,const int count) const;

public:
                     CSignalEngine(void): m_sym(NULL),
                                          m_h_ema_fast(INVALID_HANDLE),m_h_ema_slow(INVALID_HANDLE),
                                          m_h_atr(INVALID_HANDLE),m_h_adx(INVALID_HANDLE),
                                          m_h_rsi(INVALID_HANDLE),
                                          m_h_htf_fast(INVALID_HANDLE),m_h_htf_slow(INVALID_HANDLE),
                                          m_depth(0) {}
                    ~CSignalEngine(void) { Release(); }

   bool              Init(const SSettings &cfg,CSymbolCtx *sym);
   void              Release(void);
   bool              Evaluate(SSignal &out);
  };

//+------------------------------------------------------------------+
bool CSignalEngine::Init(const SSettings &cfg,CSymbolCtx *sym)
  {
   m_cfg=cfg;
   m_sym=sym;

   const string s=m_sym.symbol;

   m_h_ema_fast=iMA(s,m_cfg.entry_tf,m_cfg.ema_fast,0,MODE_EMA,PRICE_CLOSE);
   m_h_ema_slow=iMA(s,m_cfg.entry_tf,m_cfg.ema_slow,0,MODE_EMA,PRICE_CLOSE);
   m_h_atr     =iATR(s,m_cfg.entry_tf,m_cfg.atr_period);
   m_h_adx     =iADX(s,m_cfg.entry_tf,m_cfg.adx_period);
   m_h_rsi     =iRSI(s,m_cfg.entry_tf,m_cfg.rsi_period,PRICE_CLOSE);

   if(m_cfg.use_htf_filter)
     {
      m_h_htf_fast=iMA(s,m_cfg.trend_tf,m_cfg.htf_ema_fast,0,MODE_EMA,PRICE_CLOSE);
      m_h_htf_slow=iMA(s,m_cfg.trend_tf,m_cfg.htf_ema_slow,0,MODE_EMA,PRICE_CLOSE);
     }

   if(m_h_ema_fast==INVALID_HANDLE || m_h_ema_slow==INVALID_HANDLE ||
      m_h_atr==INVALID_HANDLE      || m_h_adx==INVALID_HANDLE      ||
      m_h_rsi==INVALID_HANDLE      ||
      (m_cfg.use_htf_filter && (m_h_htf_fast==INVALID_HANDLE || m_h_htf_slow==INVALID_HANDLE)))
     {
      Log.Error(StringFormat("Failed to create indicator handles (last error %d)",GetLastError()));
      return(false);
     }

   m_depth=MathMax(m_cfg.breakout_lookback+3,m_cfg.ema_slope_lookback+3);
   m_depth=MathMax(m_depth,10);

   ArraySetAsSeries(m_ema_fast,true);
   ArraySetAsSeries(m_ema_slow,true);
   ArraySetAsSeries(m_atr,true);
   ArraySetAsSeries(m_adx,true);
   ArraySetAsSeries(m_rsi,true);
   ArraySetAsSeries(m_htf_fast,true);
   ArraySetAsSeries(m_htf_slow,true);
   ArraySetAsSeries(m_rates,true);

   Log.Info(StringFormat("Signals: entry %s EMA(%d/%d), trend %s EMA(%d/%d), ADX>=%.1f",
                         TsTimeframeName(m_cfg.entry_tf),m_cfg.ema_fast,m_cfg.ema_slow,
                         m_cfg.use_htf_filter ? TsTimeframeName(m_cfg.trend_tf) : "off",
                         m_cfg.htf_ema_fast,m_cfg.htf_ema_slow,m_cfg.adx_min));
   return(true);
  }

//+------------------------------------------------------------------+
void CSignalEngine::Release(void)
  {
   if(m_h_ema_fast!=INVALID_HANDLE) { IndicatorRelease(m_h_ema_fast); m_h_ema_fast=INVALID_HANDLE; }
   if(m_h_ema_slow!=INVALID_HANDLE) { IndicatorRelease(m_h_ema_slow); m_h_ema_slow=INVALID_HANDLE; }
   if(m_h_atr!=INVALID_HANDLE)      { IndicatorRelease(m_h_atr);      m_h_atr=INVALID_HANDLE;      }
   if(m_h_adx!=INVALID_HANDLE)      { IndicatorRelease(m_h_adx);      m_h_adx=INVALID_HANDLE;      }
   if(m_h_rsi!=INVALID_HANDLE)      { IndicatorRelease(m_h_rsi);      m_h_rsi=INVALID_HANDLE;      }
   if(m_h_htf_fast!=INVALID_HANDLE) { IndicatorRelease(m_h_htf_fast); m_h_htf_fast=INVALID_HANDLE; }
   if(m_h_htf_slow!=INVALID_HANDLE) { IndicatorRelease(m_h_htf_slow); m_h_htf_slow=INVALID_HANDLE; }
  }

//+------------------------------------------------------------------+
bool CSignalEngine::HandleReady(const int handle,const ENUM_TIMEFRAMES tf) const
  {
   int calculated=BarsCalculated(handle);
   if(calculated<m_depth)
     {
      Log.Debug(StringFormat("Indicator warming up on %s (%d/%d bars)",
                             TsTimeframeName(tf),calculated,m_depth));
      return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Copies the working window of every series. Any short read means  |
//| history is still loading, so the caller stands aside this tick.  |
//+------------------------------------------------------------------+
bool CSignalEngine::Pull(void)
  {
   if(!HandleReady(m_h_ema_fast,m_cfg.entry_tf) ||
      !HandleReady(m_h_ema_slow,m_cfg.entry_tf) ||
      !HandleReady(m_h_atr,m_cfg.entry_tf)      ||
      !HandleReady(m_h_adx,m_cfg.entry_tf)      ||
      !HandleReady(m_h_rsi,m_cfg.entry_tf))
      return(false);

   if(CopyBuffer(m_h_ema_fast,0,0,m_depth,m_ema_fast)<m_depth) return(false);
   if(CopyBuffer(m_h_ema_slow,0,0,m_depth,m_ema_slow)<m_depth) return(false);
   if(CopyBuffer(m_h_atr,0,0,m_depth,m_atr)<m_depth)           return(false);
   if(CopyBuffer(m_h_adx,MAIN_LINE,0,m_depth,m_adx)<m_depth)   return(false);
   if(CopyBuffer(m_h_rsi,0,0,m_depth,m_rsi)<m_depth)           return(false);

   if(m_cfg.use_htf_filter)
     {
      if(!HandleReady(m_h_htf_fast,m_cfg.trend_tf) || !HandleReady(m_h_htf_slow,m_cfg.trend_tf))
         return(false);
      if(CopyBuffer(m_h_htf_fast,0,0,3,m_htf_fast)<3) return(false);
      if(CopyBuffer(m_h_htf_slow,0,0,3,m_htf_slow)<3) return(false);
     }

   if(CopyRates(m_sym.symbol,m_cfg.entry_tf,0,m_depth,m_rates)<m_depth)
      return(false);

   return(true);
  }

//+------------------------------------------------------------------+
double CSignalEngine::HighestHigh(const int from,const int count) const
  {
   double best=-DBL_MAX;
   int limit=MathMin(from+count,ArraySize(m_rates));
   for(int i=from;i<limit;i++)
      if(m_rates[i].high>best)
         best=m_rates[i].high;
   return(best);
  }

//+------------------------------------------------------------------+
double CSignalEngine::LowestLow(const int from,const int count) const
  {
   double best=DBL_MAX;
   int limit=MathMin(from+count,ArraySize(m_rates));
   for(int i=from;i<limit;i++)
      if(m_rates[i].low<best)
         best=m_rates[i].low;
   return(best);
  }

//+------------------------------------------------------------------+
//| Higher-timeframe bias. Returns 0 when the two EMAs are within    |
//| noise of each other, which keeps the EA out of chop.             |
//+------------------------------------------------------------------+
int CSignalEngine::EvaluateBias(void) const
  {
   if(!m_cfg.use_htf_filter)
      return(0);

   double f=m_htf_fast[1];
   double s=m_htf_slow[1];
   double noise=m_sym.point*2.0;

   if(f>s+noise) return(1);
   if(f<s-noise) return(-1);
   return(0);
  }

//+------------------------------------------------------------------+
//| Entry-timeframe trend: EMA stack plus a slope of the same sign.  |
//+------------------------------------------------------------------+
int CSignalEngine::EvaluateTrend(void) const
  {
   int back=1+m_cfg.ema_slope_lookback;
   if(back>=ArraySize(m_ema_fast))
      return(0);

   double fast=m_ema_fast[1];
   double slow=m_ema_slow[1];
   double slope=fast-m_ema_fast[back];

   if(fast>slow && slope>0.0) return(1);
   if(fast<slow && slope<0.0) return(-1);
   return(0);
  }

//+------------------------------------------------------------------+
//| RSI veto: refuse to buy a blow-off top or sell a capitulation.   |
//+------------------------------------------------------------------+
bool CSignalEngine::RsiAllows(const int dir) const
  {
   double r=m_rsi[1];
   if(dir>0)
      return(r>=m_cfg.rsi_buy_min && r<=m_cfg.rsi_buy_max);
   if(dir<0)
      return(r>=m_cfg.rsi_sell_min && r<=m_cfg.rsi_sell_max);
   return(false);
  }

//+------------------------------------------------------------------+
//| Trigger check against the live price.                            |
//+------------------------------------------------------------------+
bool CSignalEngine::TriggerFires(const int dir,string &why) const
  {
   double atr=m_atr[1];
   if(atr<=0.0)
     {
      why="atr unavailable";
      return(false);
     }

   double ask=m_sym.Ask();
   double bid=m_sym.Bid();
   bool   want_pullback=(m_cfg.entry_mode!=TS_ENTRY_BREAKOUT);
   bool   want_breakout=(m_cfg.entry_mode!=TS_ENTRY_PULLBACK);

   if(dir>0)
     {
      if(want_pullback)
        {
         bool dipped =(m_rates[1].low<=m_ema_fast[1]+m_cfg.pullback_depth_atr*atr);
         bool held   =(m_rates[1].close>m_ema_fast[1]);
         bool bullish=(m_rates[1].close>m_rates[1].open);
         if(dipped && held && bullish && ask>m_rates[1].high)
           {
            why="pullback resumed above prior bar high";
            return(true);
           }
        }
      if(want_breakout)
        {
         double hh=HighestHigh(1,m_cfg.breakout_lookback);
         if(hh>-DBL_MAX && ask>hh+m_cfg.breakout_buffer_atr*atr)
           {
            why=StringFormat("broke %d-bar high",m_cfg.breakout_lookback);
            return(true);
           }
        }
      why="no long trigger";
      return(false);
     }

   if(dir<0)
     {
      if(want_pullback)
        {
         bool popped =(m_rates[1].high>=m_ema_fast[1]-m_cfg.pullback_depth_atr*atr);
         bool held   =(m_rates[1].close<m_ema_fast[1]);
         bool bearish=(m_rates[1].close<m_rates[1].open);
         if(popped && held && bearish && bid<m_rates[1].low)
           {
            why="pullback resumed below prior bar low";
            return(true);
           }
        }
      if(want_breakout)
        {
         double ll=LowestLow(1,m_cfg.breakout_lookback);
         if(ll<DBL_MAX && bid<ll-m_cfg.breakout_buffer_atr*atr)
           {
            why=StringFormat("broke %d-bar low",m_cfg.breakout_lookback);
            return(true);
           }
        }
      why="no short trigger";
      return(false);
     }

   why="no direction";
   return(false);
  }

//+------------------------------------------------------------------+
bool CSignalEngine::Evaluate(SSignal &out)
  {
   out.direction=0;
   out.bias=0;
   out.trend=0;
   out.atr=0.0;
   out.adx=0.0;
   out.rsi=0.0;
   out.ema_fast=0.0;
   out.ema_slow=0.0;
   out.bar_time=0;
   out.reason="";
   out.ready=false;

   if(!Pull())
     {
      out.reason="warming up";
      return(false);
     }

   out.ready    = true;
   out.atr      = m_atr[1];
   out.adx      = m_adx[1];
   out.rsi      = m_rsi[1];
   out.ema_fast = m_ema_fast[1];
   out.ema_slow = m_ema_slow[1];
   out.bar_time = m_rates[0].time;
   out.trend    = EvaluateTrend();
   out.bias     = EvaluateBias();

   if(out.trend==0)
     {
      out.reason="no trend on entry timeframe";
      return(false);
     }
   if(m_cfg.use_htf_filter && out.bias!=out.trend)
     {
      out.reason=StringFormat("higher timeframe disagrees (bias %s)",TsDirName(out.bias));
      return(false);
     }
   if(out.adx<m_cfg.adx_min)
     {
      out.reason=StringFormat("ADX %.1f below %.1f",out.adx,m_cfg.adx_min);
      return(false);
     }
   if(!RsiAllows(out.trend))
     {
      out.reason=StringFormat("RSI %.1f outside entry band",out.rsi);
      return(false);
     }

   string why="";
   if(!TriggerFires(out.trend,why))
     {
      out.reason=why;
      return(false);
     }

   out.direction=out.trend;
   out.reason=why;
   return(true);
  }

#endif // TS_SIGNALENGINE_MQH
