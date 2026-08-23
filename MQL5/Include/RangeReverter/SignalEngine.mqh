//+------------------------------------------------------------------+
//|                                                 SignalEngine.mqh |
//|   Range detection and fade triggers.                             |
//|                                                                  |
//|   This is the mirror image of a trend follower. Direction comes  |
//|   from four layers, and the first two are veto layers - most of  |
//|   the work is deciding NOT to trade:                             |
//|     1. regime: ADX under a ceiling, and (optionally) a flat      |
//|        higher timeframe. A trending market is not fadeable.      |
//|     2. edge: the trip from the band back to the mean must be     |
//|        worth both an ATR fraction and several spreads, or the    |
//|        round trip cannot pay for itself.                         |
//|     3. extreme: price at or through a Bollinger band, with RSI   |
//|        stretched the same way.                                   |
//|     4. trigger: either the touch itself, or a bar that pierced   |
//|        the band and closed back inside it.                       |
//|   Two vetoes sit on top of the extreme: a band being ridden by   |
//|   consecutive closes outside it is a trend leg, not an extreme,  |
//|   and a bar much larger than ATR is a knife, not a fade.         |
//+------------------------------------------------------------------+
#ifndef RR_SIGNALENGINE_MQH
#define RR_SIGNALENGINE_MQH

#include <RangeReverter/Config.mqh>
#include <RangeReverter/Utils.mqh>

//--- iBands buffer order, named here rather than relying on the platform
//--- constants being in scope for every build.
#define RR_BAND_MID   0
#define RR_BAND_UPPER 1
#define RR_BAND_LOWER 2

//+------------------------------------------------------------------+
struct SRrSignal
  {
   int               direction;     // +1 fade up from the lower band, -1 fade down from the upper
   int               extreme;       // which band price is at, before the vetoes
   bool              ranging;       // regime says the market is fadeable
   double            atr;
   double            adx;
   double            rsi;
   double            upper;
   double            mid;
   double            lower;
   double            edge;          // band-to-mean distance in price
   double            width_ratio;   // band width vs its own recent average
   double            htf_stretch;   // HTF EMA separation in HTF ATR (0 when the filter is off)
   datetime          bar_time;
   string            reason;        // why we did / did not fire, in words
   string            tag;           // same thing from a fixed vocabulary, for the tally
   bool              ready;         // indicator data usable this tick
  };

//+------------------------------------------------------------------+
class CRrSignalEngine
  {
private:
   SRrSettings       m_cfg;
   CRrSymbolCtx     *m_sym;

   int               m_h_bands;
   int               m_h_atr;
   int               m_h_adx;
   int               m_h_rsi;
   int               m_h_htf_fast;
   int               m_h_htf_slow;
   int               m_h_htf_atr;

   int               m_depth;        // bars to pull each refresh

   double            m_upper[];
   double            m_mid[];
   double            m_lower[];
   double            m_atr[];
   double            m_adx[];
   double            m_rsi[];
   double            m_htf_fast[];
   double            m_htf_slow[];
   double            m_htf_atr[];
   MqlRates          m_rates[];

   bool              Pull(string &why,string &tag);
   bool              HandleReady(const int handle,const ENUM_TIMEFRAMES tf,
                                 const string name,string &why,string &tag) const;
   bool              Take(const int handle,const int buffer,const int count,double &dst[],
                          const string name,string &why,string &tag) const;
   double            WidthRatio(void) const;
   double            HtfStretch(void) const;
   int               ExtremeSide(void) const;
   int               RideBars(const int dir) const;
   bool              TriggerFires(const int dir,string &why,string &tag) const;

public:
                     CRrSignalEngine(void): m_sym(NULL),
                                            m_h_bands(INVALID_HANDLE),m_h_atr(INVALID_HANDLE),
                                            m_h_adx(INVALID_HANDLE),m_h_rsi(INVALID_HANDLE),
                                            m_h_htf_fast(INVALID_HANDLE),m_h_htf_slow(INVALID_HANDLE),
                                            m_h_htf_atr(INVALID_HANDLE),
                                            m_depth(0) {}
                    ~CRrSignalEngine(void) { Release(); }

   bool              Init(const SRrSettings &cfg,CRrSymbolCtx *sym);
   void              Release(void);
   bool              Evaluate(SRrSignal &out);
  };

//+------------------------------------------------------------------+
bool CRrSignalEngine::Init(const SRrSettings &cfg,CRrSymbolCtx *sym)
  {
   m_cfg=cfg;
   m_sym=sym;

   const string s=m_sym.symbol;

   m_h_bands=iBands(s,m_cfg.entry_tf,m_cfg.band_period,0,m_cfg.band_deviation,PRICE_CLOSE);
   m_h_atr  =iATR(s,m_cfg.entry_tf,m_cfg.atr_period);
   m_h_adx  =iADX(s,m_cfg.entry_tf,m_cfg.adx_period);
   m_h_rsi  =iRSI(s,m_cfg.entry_tf,m_cfg.rsi_period,PRICE_CLOSE);

   if(m_cfg.use_htf_filter)
     {
      m_h_htf_fast=iMA(s,m_cfg.trend_tf,m_cfg.htf_ema_fast,0,MODE_EMA,PRICE_CLOSE);
      m_h_htf_slow=iMA(s,m_cfg.trend_tf,m_cfg.htf_ema_slow,0,MODE_EMA,PRICE_CLOSE);
      m_h_htf_atr =iATR(s,m_cfg.trend_tf,m_cfg.atr_period);
     }

   if(m_h_bands==INVALID_HANDLE || m_h_atr==INVALID_HANDLE ||
      m_h_adx==INVALID_HANDLE   || m_h_rsi==INVALID_HANDLE ||
      (m_cfg.use_htf_filter && (m_h_htf_fast==INVALID_HANDLE ||
                                m_h_htf_slow==INVALID_HANDLE ||
                                m_h_htf_atr==INVALID_HANDLE)))
     {
      RLog.Error(StringFormat("Failed to create indicator handles (last error %d)",GetLastError()));
      return(false);
     }

   //--- deep enough for the ride check, the width average and a little slack
   m_depth=MathMax(m_cfg.max_ride_bars+3,m_cfg.band_period+3);
   m_depth=MathMax(m_depth,26);

   ArraySetAsSeries(m_upper,true);
   ArraySetAsSeries(m_mid,true);
   ArraySetAsSeries(m_lower,true);
   ArraySetAsSeries(m_atr,true);
   ArraySetAsSeries(m_adx,true);
   ArraySetAsSeries(m_rsi,true);
   ArraySetAsSeries(m_htf_fast,true);
   ArraySetAsSeries(m_htf_slow,true);
   ArraySetAsSeries(m_htf_atr,true);
   ArraySetAsSeries(m_rates,true);

   RLog.Info(StringFormat("Signals: entry %s Bollinger(%d, %.2f), ADX<=%.1f, RSI %.0f/%.0f, flatness %s",
                          RrTimeframeName(m_cfg.entry_tf),m_cfg.band_period,m_cfg.band_deviation,
                          m_cfg.adx_max,m_cfg.rsi_oversold,m_cfg.rsi_overbought,
                          m_cfg.use_htf_filter ? RrTimeframeName(m_cfg.trend_tf) : "off"));
   return(true);
  }

//+------------------------------------------------------------------+
void CRrSignalEngine::Release(void)
  {
   if(m_h_bands!=INVALID_HANDLE)    { IndicatorRelease(m_h_bands);    m_h_bands=INVALID_HANDLE;    }
   if(m_h_atr!=INVALID_HANDLE)      { IndicatorRelease(m_h_atr);      m_h_atr=INVALID_HANDLE;      }
   if(m_h_adx!=INVALID_HANDLE)      { IndicatorRelease(m_h_adx);      m_h_adx=INVALID_HANDLE;      }
   if(m_h_rsi!=INVALID_HANDLE)      { IndicatorRelease(m_h_rsi);      m_h_rsi=INVALID_HANDLE;      }
   if(m_h_htf_fast!=INVALID_HANDLE) { IndicatorRelease(m_h_htf_fast); m_h_htf_fast=INVALID_HANDLE; }
   if(m_h_htf_slow!=INVALID_HANDLE) { IndicatorRelease(m_h_htf_slow); m_h_htf_slow=INVALID_HANDLE; }
   if(m_h_htf_atr!=INVALID_HANDLE)  { IndicatorRelease(m_h_htf_atr);  m_h_htf_atr=INVALID_HANDLE;  }
  }

//+------------------------------------------------------------------+
bool CRrSignalEngine::HandleReady(const int handle,const ENUM_TIMEFRAMES tf,
                                  const string name,string &why,string &tag) const
  {
   int calculated=BarsCalculated(handle);
   if(calculated<m_depth)
     {
      why=StringFormat("%s on %s has %d of the %d bars it needs",
                       name,RrTimeframeName(tf),calculated,m_depth);
      tag="no data: "+name;
      return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| One buffer copy that says which series came up short.            |
//+------------------------------------------------------------------+
bool CRrSignalEngine::Take(const int handle,const int buffer,const int count,double &dst[],
                           const string name,string &why,string &tag) const
  {
   int got=CopyBuffer(handle,buffer,0,count,dst);
   if(got<count)
     {
      why=StringFormat("%s returned %d of %d bars (error %d)",name,got,count,GetLastError());
      tag="short read: "+name;
      return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Copies the working window of every series. Any short read means  |
//| history is still loading, so the caller stands aside this tick.  |
//+------------------------------------------------------------------+
bool CRrSignalEngine::Pull(string &why,string &tag)
  {
   if(!HandleReady(m_h_bands,m_cfg.entry_tf,"Bollinger bands",why,tag)) return(false);
   if(!HandleReady(m_h_atr,m_cfg.entry_tf,"ATR",why,tag))               return(false);
   if(!HandleReady(m_h_adx,m_cfg.entry_tf,"ADX",why,tag))               return(false);
   if(!HandleReady(m_h_rsi,m_cfg.entry_tf,"RSI",why,tag))               return(false);

   if(!Take(m_h_bands,RR_BAND_MID,m_depth,m_mid,"middle band",why,tag))   return(false);
   if(!Take(m_h_bands,RR_BAND_UPPER,m_depth,m_upper,"upper band",why,tag)) return(false);
   if(!Take(m_h_bands,RR_BAND_LOWER,m_depth,m_lower,"lower band",why,tag)) return(false);
   if(!Take(m_h_atr,0,m_depth,m_atr,"ATR",why,tag))                     return(false);
   if(!Take(m_h_adx,MAIN_LINE,m_depth,m_adx,"ADX",why,tag))             return(false);
   if(!Take(m_h_rsi,0,m_depth,m_rsi,"RSI",why,tag))                     return(false);

   if(m_cfg.use_htf_filter)
     {
      if(!HandleReady(m_h_htf_fast,m_cfg.trend_tf,"trend fast EMA",why,tag)) return(false);
      if(!HandleReady(m_h_htf_slow,m_cfg.trend_tf,"trend slow EMA",why,tag)) return(false);
      if(!HandleReady(m_h_htf_atr,m_cfg.trend_tf,"trend ATR",why,tag))       return(false);
      if(!Take(m_h_htf_fast,0,3,m_htf_fast,"trend fast EMA",why,tag))        return(false);
      if(!Take(m_h_htf_slow,0,3,m_htf_slow,"trend slow EMA",why,tag))        return(false);
      if(!Take(m_h_htf_atr,0,3,m_htf_atr,"trend ATR",why,tag))               return(false);
     }

   int bars=CopyRates(m_sym.symbol,m_cfg.entry_tf,0,m_depth,m_rates);
   if(bars<m_depth)
     {
      why=StringFormat("price history for %s %s returned %d of %d bars (error %d)",
                       m_sym.symbol,RrTimeframeName(m_cfg.entry_tf),bars,m_depth,GetLastError());
      tag="no data: price history";
      return(false);
     }

   return(true);
  }

//+------------------------------------------------------------------+
//| Current band width against the average of the preceding bars. A  |
//| ratio well above 1 means the bands are opening up, which is what |
//| the start of a breakout looks like from inside a range.          |
//+------------------------------------------------------------------+
double CRrSignalEngine::WidthRatio(void) const
  {
   const int window=20;
   int limit=MathMin(2+window,ArraySize(m_upper));
   if(limit<=3)
      return(1.0);

   double sum=0.0;
   int    n=0;
   for(int i=2;i<limit;i++)
     {
      sum+=(m_upper[i]-m_lower[i]);
      n++;
     }
   if(n==0 || sum<=0.0)
      return(1.0);

   double avg=sum/n;
   double now=m_upper[1]-m_lower[1];
   return(avg>0.0 ? now/avg : 1.0);
  }

//+------------------------------------------------------------------+
//| How far apart the higher-timeframe EMAs are, measured in that    |
//| timeframe's own ATR. Small means flat, which is what a range     |
//| looks like from above. Returns 0 when the filter is off.         |
//+------------------------------------------------------------------+
double CRrSignalEngine::HtfStretch(void) const
  {
   if(!m_cfg.use_htf_filter)
      return(0.0);

   double atr=m_htf_atr[1];
   if(atr<=0.0)
      return(0.0);
   return(MathAbs(m_htf_fast[1]-m_htf_slow[1])/atr);
  }

//+------------------------------------------------------------------+
//| Which band price is at right now, using the price we would       |
//| actually transact at: the ask for a long, the bid for a short.   |
//| Returns +1 at the lower band (a long fade), -1 at the upper.     |
//+------------------------------------------------------------------+
int CRrSignalEngine::ExtremeSide(void) const
  {
   double ask=m_sym.Ask();
   double bid=m_sym.Bid();
   double low_edge =m_lower[1];
   double high_edge=m_upper[1];

   //--- live price at a band settles it outright
   if(ask<=low_edge)
      return(1);
   if(bid>=high_edge)
      return(-1);

   //--- otherwise the last closed bar counts, so a wick through the band
   //--- still registers after price has come back inside. A bar that
   //--- pierced BOTH bands says nothing about which way to fade.
   bool wicked_low =(m_rates[1].low<=low_edge);
   bool wicked_high=(m_rates[1].high>=high_edge);
   if(wicked_low && wicked_high)
      return(0);
   if(wicked_low)
      return(1);
   if(wicked_high)
      return(-1);
   return(0);
  }

//+------------------------------------------------------------------+
//| Consecutive closed bars that finished outside the band on the    |
//| side we are being asked to fade. Two or more is a trend leg      |
//| walking the band, not an extreme worth buying.                   |
//+------------------------------------------------------------------+
int CRrSignalEngine::RideBars(const int dir) const
  {
   int count=0;
   int limit=MathMin(1+m_cfg.max_ride_bars+2,ArraySize(m_rates));

   for(int i=1;i<limit;i++)
     {
      bool outside=(dir>0) ? (m_rates[i].close<m_lower[i]) : (m_rates[i].close>m_upper[i]);
      if(!outside)
         break;
      count++;
     }
   return(count);
  }

//+------------------------------------------------------------------+
//| Trigger check against the live price.                            |
//+------------------------------------------------------------------+
bool CRrSignalEngine::TriggerFires(const int dir,string &why,string &tag) const
  {
   double atr=m_atr[1];
   if(atr<=0.0)
     {
      why="atr unavailable";
      tag="ATR unavailable";
      return(false);
     }

   double ask=m_sym.Ask();
   double bid=m_sym.Bid();
   double buffer=m_cfg.touch_buffer_atr*atr;
   bool   want_touch =(m_cfg.entry_mode!=RR_ENTRY_REJECT);
   bool   want_reject=(m_cfg.entry_mode!=RR_ENTRY_TOUCH);

   if(dir>0)
     {
      if(want_touch && ask<=m_lower[1]-buffer)
        {
         why="ask traded through the lower band";
         tag="entry signal";
         return(true);
        }
      if(want_reject)
        {
         //--- the last closed bar dipped under the band and closed back inside;
         //--- entering above its high is the market confirming the rejection
         bool pierced =(m_rates[1].low<=m_lower[1]);
         bool recovered=(m_rates[1].close>m_lower[1]);
         if(pierced && recovered && ask>m_rates[1].high)
           {
            why="bar rejected the lower band and price took out its high";
            tag="entry signal";
            return(true);
           }
        }
      why="price has not triggered at the lower band";
      tag=want_reject && !want_touch ? "no rejection bar yet" : "no touch of the band";
      return(false);
     }

   if(dir<0)
     {
      if(want_touch && bid>=m_upper[1]+buffer)
        {
         why="bid traded through the upper band";
         tag="entry signal";
         return(true);
        }
      if(want_reject)
        {
         bool pierced  =(m_rates[1].high>=m_upper[1]);
         bool recovered=(m_rates[1].close<m_upper[1]);
         if(pierced && recovered && bid<m_rates[1].low)
           {
            why="bar rejected the upper band and price took out its low";
            tag="entry signal";
            return(true);
           }
        }
      why="price has not triggered at the upper band";
      tag=want_reject && !want_touch ? "no rejection bar yet" : "no touch of the band";
      return(false);
     }

   why="no direction";
   tag="no direction";
   return(false);
  }

//+------------------------------------------------------------------+
bool CRrSignalEngine::Evaluate(SRrSignal &out)
  {
   out.direction   = 0;
   out.extreme     = 0;
   out.ranging     = false;
   out.atr         = 0.0;
   out.adx         = 0.0;
   out.rsi         = 0.0;
   out.upper       = 0.0;
   out.mid         = 0.0;
   out.lower       = 0.0;
   out.edge        = 0.0;
   out.width_ratio = 0.0;
   out.htf_stretch = 0.0;
   out.bar_time    = 0;
   out.reason      = "";
   out.tag         = "";
   out.ready       = false;

   string pull_why="";
   string pull_tag="";
   if(!Pull(pull_why,pull_tag))
     {
      out.reason=pull_why;
      out.tag=pull_tag;
      return(false);
     }

   out.ready       = true;
   out.atr         = m_atr[1];
   out.adx         = m_adx[1];
   out.rsi         = m_rsi[1];
   out.upper       = m_upper[1];
   out.mid         = m_mid[1];
   out.lower       = m_lower[1];
   out.edge        = MathMax(m_upper[1]-m_mid[1],m_mid[1]-m_lower[1]);
   out.width_ratio = WidthRatio();
   out.htf_stretch = HtfStretch();
   out.bar_time    = m_rates[0].time;

   if(out.atr<=0.0)
     {
      out.reason="atr unavailable";
      out.tag="ATR unavailable";
      return(false);
     }

   //--- 1. regime: is this a range at all?
   if(out.adx>m_cfg.adx_max)
     {
      out.reason=StringFormat("ADX %.1f above the %.1f range ceiling",out.adx,m_cfg.adx_max);
      out.tag="ADX above range ceiling";
      return(false);
     }
   if(m_cfg.use_htf_filter && out.htf_stretch>m_cfg.htf_flat_atr)
     {
      out.reason=StringFormat("higher timeframe stretched %.2f ATR (limit %.2f)",
                              out.htf_stretch,m_cfg.htf_flat_atr);
      out.tag="higher timeframe is trending";
      return(false);
     }
   if(m_cfg.band_expansion_max>0.0 && out.width_ratio>m_cfg.band_expansion_max)
     {
      out.reason=StringFormat("bands %.0f%% of their average width - expanding",
                              out.width_ratio*100.0);
      out.tag="bands expanding (breakout)";
      return(false);
     }

   out.ranging=true;

   //--- 2. edge: is the trip back to the mean worth taking?
   if(out.edge<m_cfg.min_edge_atr*out.atr)
     {
      out.reason=StringFormat("band-to-mean %.2f ATR, below the %.2f floor",
                              out.edge/out.atr,m_cfg.min_edge_atr);
      out.tag="edge below the ATR floor";
      return(false);
     }
   if(m_cfg.min_edge_spreads>0.0)
     {
      double spread=m_sym.Spread();
      if(spread>0.0 && out.edge<m_cfg.min_edge_spreads*spread)
        {
         out.reason=StringFormat("band-to-mean is %.1f spreads, below the %.1f floor",
                                 out.edge/spread,m_cfg.min_edge_spreads);
         out.tag="edge does not cover the spread";
         return(false);
        }
     }

   //--- 3. extreme: is price actually at a band, stretched, and fadeable?
   out.extreme=ExtremeSide();
   if(out.extreme==0)
     {
      out.reason="price is inside the bands";
      out.tag="price inside the bands";
      return(false);
     }

   int ride=RideBars(out.extreme);
   if(ride>m_cfg.max_ride_bars)
     {
      out.reason=StringFormat("%d consecutive closes outside the band",ride);
      out.tag="band being ridden (trend leg)";
      return(false);
     }

   if(m_cfg.max_bar_atr>0.0)
     {
      double bar_range=m_rates[1].high-m_rates[1].low;
      if(bar_range>m_cfg.max_bar_atr*out.atr)
        {
         out.reason=StringFormat("last bar spanned %.1f ATR (limit %.1f)",
                                 bar_range/out.atr,m_cfg.max_bar_atr);
         out.tag="bar range too violent to fade";
         return(false);
        }
     }

   bool rsi_ok=(out.extreme>0) ? (out.rsi<=m_cfg.rsi_oversold)
                               : (out.rsi>=m_cfg.rsi_overbought);
   if(!rsi_ok)
     {
      out.reason=StringFormat("RSI %.1f is not stretched with price",out.rsi);
      out.tag="RSI not stretched";
      return(false);
     }

   //--- 4. trigger
   string why="";
   string tag="";
   if(!TriggerFires(out.extreme,why,tag))
     {
      out.reason=why;
      out.tag=tag;
      return(false);
     }

   out.direction=out.extreme;
   out.reason=why;
   out.tag=tag;
   return(true);
  }

#endif // RR_SIGNALENGINE_MQH
