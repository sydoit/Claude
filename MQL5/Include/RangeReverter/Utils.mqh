//+------------------------------------------------------------------+
//|                                                        Utils.mqh |
//|   Symbol metadata cache, price/lot normalisation, time windows.  |
//+------------------------------------------------------------------+
#ifndef RR_UTILS_MQH
#define RR_UTILS_MQH

#include <RangeReverter/Logger.mqh>

//+------------------------------------------------------------------+
//| Everything about the traded symbol that the EA needs on a tick.  |
//| Cached once in OnInit so we are not hammering SymbolInfo* calls  |
//| inside the hot path.                                             |
//+------------------------------------------------------------------+
class CRrSymbolCtx
  {
public:
   string            symbol;
   int               digits;
   double            point;
   double            tick_size;
   double            tick_value;
   double            vol_min;
   double            vol_max;
   double            vol_step;
   int               vol_digits;
   int               stops_level;      // points
   int               freeze_level;     // points

                     CRrSymbolCtx(void): symbol(""),digits(0),point(0),tick_size(0),tick_value(0),
                                       vol_min(0),vol_max(0),vol_step(0),vol_digits(2),
                                       stops_level(0),freeze_level(0) {}

   bool              Init(const string sym);
   void              RefreshLevels(void);

   double            Ask(void)    const { return(SymbolInfoDouble(symbol,SYMBOL_ASK)); }
   double            Bid(void)    const { return(SymbolInfoDouble(symbol,SYMBOL_BID)); }
   double            Spread(void) const { return(Ask()-Bid()); }
   double            SpreadPoints(void) const { return(point>0 ? (Ask()-Bid())/point : 0.0); }

   double            NormalizePrice(const double price) const
     {
      if(tick_size>0)
         return(NormalizeDouble(MathRound(price/tick_size)*tick_size,digits));
      return(NormalizeDouble(price,digits));
     }

   //--- Always rounds DOWN to the volume step so a size derived from a
   //--- risk budget can never come out larger than intended.
   double            FloorLots(const double lots) const
     {
      if(vol_step<=0.0)
         return(0.0);
      double v=MathFloor(lots/vol_step+1e-8)*vol_step;
      if(v>vol_max)
         v=vol_max;
      return(NormalizeDouble(v,vol_digits));
     }

   bool              LotsTradable(const double lots) const
     {
      return(lots>=vol_min-1e-8 && lots<=vol_max+1e-8);
     }

   //--- Minimum distance (in price) that SL/TP must keep from the market.
   //--- Brokers reporting stops_level==0 use a dynamic, spread-based limit,
   //--- so we always keep a spread-sized cushion on top.
   double            MinStopDistance(void) const
     {
      double broker=stops_level*point;
      double cushion=Spread()+2.0*point;
      return(MathMax(broker,cushion));
     }

   double            FreezeDistance(void) const { return(freeze_level*point); }

   string            LotsToString(const double lots) const { return(DoubleToString(lots,vol_digits)); }
   string            PriceToString(const double price) const { return(DoubleToString(price,digits)); }
  };

//+------------------------------------------------------------------+
bool CRrSymbolCtx::Init(const string sym)
  {
   symbol=sym;

   if(!SymbolSelect(symbol,true))
     {
      RLog.Error(StringFormat("Symbol %s could not be selected in Market Watch",symbol));
      return(false);
     }

   digits     = (int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
   point      = SymbolInfoDouble(symbol,SYMBOL_POINT);
   tick_size  = SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_SIZE);
   tick_value = SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_VALUE);
   vol_min    = SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
   vol_max    = SymbolInfoDouble(symbol,SYMBOL_VOLUME_MAX);
   vol_step   = SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);

   if(point<=0.0 || vol_step<=0.0 || vol_min<=0.0)
     {
      RLog.Error(StringFormat("Incomplete symbol spec for %s (point=%g volStep=%g volMin=%g)",
                             symbol,point,vol_step,vol_min));
      return(false);
     }

   if(tick_size<=0.0)
      tick_size=point;

   //--- how many decimals the volume step carries (0.01 -> 2)
   vol_digits=0;
   double step=vol_step;
   while(vol_digits<8 && MathAbs(step-MathRound(step))>1e-8)
     {
      step*=10.0;
      vol_digits++;
     }

   RefreshLevels();

   RLog.Info(StringFormat("Symbol %s: digits=%d point=%g volMin=%s volStep=%s stops=%dpt freeze=%dpt",
                         symbol,digits,point,LotsToString(vol_min),LotsToString(vol_step),
                         stops_level,freeze_level));
   return(true);
  }

//+------------------------------------------------------------------+
void CRrSymbolCtx::RefreshLevels(void)
  {
   stops_level  = (int)SymbolInfoInteger(symbol,SYMBOL_TRADE_STOPS_LEVEL);
   freeze_level = (int)SymbolInfoInteger(symbol,SYMBOL_TRADE_FREEZE_LEVEL);
  }

//+------------------------------------------------------------------+
//| A list of intraday windows written as "HH:MM-HH:MM,HH:MM-HH:MM". |
//| Used both for trading sessions and for news blackouts. Windows   |
//| may wrap past midnight (e.g. "22:00-02:00"). All times are       |
//| broker/server time, which is what TimeCurrent() returns.         |
//+------------------------------------------------------------------+
class CRrTimeWindows
  {
private:
   int               m_from[];   // minutes since midnight
   int               m_to[];

   static bool       ParseClock(const string txt,int &minutes)
     {
      string parts[];
      if(StringSplit(txt,':',parts)!=2)
         return(false);
      int h=(int)StringToInteger(parts[0]);
      int m=(int)StringToInteger(parts[1]);
      if(h<0 || h>23 || m<0 || m>59)
         return(false);
      minutes=h*60+m;
      return(true);
     }

public:
                     CRrTimeWindows(void) {}

   bool              IsEmpty(void) const { return(ArraySize(m_from)==0); }

   //--- Returns false (and logs) if the spec is malformed, so OnInit can abort.
   bool              Parse(const string spec)
     {
      ArrayResize(m_from,0);
      ArrayResize(m_to,0);

      string trimmed=spec;
      StringTrimLeft(trimmed);
      StringTrimRight(trimmed);
      if(trimmed=="")
         return(true);

      string items[];
      int n=StringSplit(trimmed,',',items);
      for(int i=0;i<n;i++)
        {
         string item=items[i];
         StringTrimLeft(item);
         StringTrimRight(item);
         if(item=="")
            continue;

         string edges[];
         int from_min,to_min;
         if(StringSplit(item,'-',edges)!=2 ||
            !ParseClock(edges[0],from_min) ||
            !ParseClock(edges[1],to_min))
           {
            RLog.Error(StringFormat("Bad time window '%s' - expected HH:MM-HH:MM",item));
            return(false);
           }

         int sz=ArraySize(m_from);
         ArrayResize(m_from,sz+1);
         ArrayResize(m_to,sz+1);
         m_from[sz]=from_min;
         m_to[sz]=to_min;
        }
      return(true);
     }

   bool              Contains(const datetime when) const
     {
      MqlDateTime dt;
      TimeToStruct(when,dt);
      return(ContainsMinute(dt.hour*60+dt.min));
     }

   bool              ContainsMinute(const int now) const
     {
      int cnt=ArraySize(m_from);
      if(cnt==0)
         return(false);

      for(int i=0;i<cnt;i++)
        {
         int a=m_from[i];
         int b=m_to[i];
         if(a==b)                       // degenerate window: treat as whole day
            return(true);
         if(a<b)
           {
            if(now>=a && now<b)
               return(true);
           }
         else                           // wraps past midnight
           {
            if(now>=a || now<b)
               return(true);
           }
        }
      return(false);
     }
  };

//+------------------------------------------------------------------+
string RrDirName(const int dir)
  {
   if(dir>0) return("BUY");
   if(dir<0) return("SELL");
   return("NONE");
  }

//+------------------------------------------------------------------+
//--- "PERIOD_M15" -> "M15"
string RrTimeframeName(const ENUM_TIMEFRAMES tf)
  {
   string name=EnumToString(tf);
   return(StringSubstr(name,0,7)=="PERIOD_" ? StringSubstr(name,7) : name);
  }

#endif // RR_UTILS_MQH
