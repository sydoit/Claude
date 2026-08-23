//+------------------------------------------------------------------+
//|                                                      Filters.mqh |
//|   Cheap "should we even look at a signal right now" checks:      |
//|   trading sessions, news blackouts, weekday rules, spread and    |
//|   the entry cooldown.                                            |
//+------------------------------------------------------------------+
#ifndef RR_FILTERS_MQH
#define RR_FILTERS_MQH

#include <RangeReverter/Config.mqh>
#include <RangeReverter/Utils.mqh>

//+------------------------------------------------------------------+
class CRrFilters
  {
private:
   SRrSettings         m_cfg;
   CRrSymbolCtx       *m_sym;
   CRrTimeWindows      m_sessions;
   CRrTimeWindows      m_blackout;
   datetime          m_last_entry;

   bool              WeekdayAllowed(const datetime now) const
     {
      MqlDateTime dt;
      TimeToStruct(now,dt);
      switch(dt.day_of_week)
        {
         case 1:  return(m_cfg.trade_monday);
         case 2:  return(m_cfg.trade_tuesday);
         case 3:  return(m_cfg.trade_wednesday);
         case 4:  return(m_cfg.trade_thursday);
         case 5:  return(m_cfg.trade_friday);
         default: return(false);          // weekend
        }
     }

public:
                     CRrFilters(void): m_sym(NULL),m_last_entry(0) {}

   bool              Init(const SRrSettings &cfg,CRrSymbolCtx *sym);

   void              NoteEntry(const datetime when) { m_last_entry=when; }

   bool              SpreadOk(const double atr,string &reason,string &tag) const;
   bool              ScheduleOk(const datetime now,string &reason,string &tag) const;
   bool              CooldownOk(const datetime now,string &reason,string &tag) const;
   bool              FridayFlatten(const datetime now) const;
   bool              CanEnter(const datetime now,const double atr,string &reason,string &tag) const;

   //--- start-up sanity: do the configured windows ever overlap the
   //--- hours the broker actually quotes this symbol?
   int               OverlapMinutes(const string symbol,const int day_of_week) const;
   void              ReportSessionOverlap(const string symbol) const;
  };

//+------------------------------------------------------------------+
bool CRrFilters::Init(const SRrSettings &cfg,CRrSymbolCtx *sym)
  {
   m_cfg=cfg;
   m_sym=sym;

   if(!m_sessions.Parse(m_cfg.sessions))
      return(false);
   if(!m_blackout.Parse(m_cfg.blackout))
      return(false);

   RLog.Info(StringFormat("Schedule: sessions [%s] blackout [%s] (server time)",
                         m_cfg.sessions=="" ? "24h" : m_cfg.sessions,
                         m_cfg.blackout=="" ? "none" : m_cfg.blackout));
   return(true);
  }

//+------------------------------------------------------------------+
//| Two ceilings: an absolute one in points and a relative one as a  |
//| fraction of ATR. The relative one keeps the EA honest when       |
//| volatility collapses and the spread quietly eats the edge.       |
//+------------------------------------------------------------------+
bool CRrFilters::SpreadOk(const double atr,string &reason,string &tag) const
  {
   double spread_points=m_sym.SpreadPoints();

   if(m_cfg.max_spread_points>0.0 && spread_points>m_cfg.max_spread_points)
     {
      reason=StringFormat("spread %.1fpt above the %.1fpt ceiling",spread_points,m_cfg.max_spread_points);
      tag="spread above the points ceiling";
      return(false);
     }
   if(m_cfg.max_spread_atr>0.0 && atr>0.0)
     {
      double spread=m_sym.Spread();
      if(spread>atr*m_cfg.max_spread_atr)
        {
         reason=StringFormat("spread is %.0f%% of ATR (limit %.0f%%)",
                             spread/atr*100.0,m_cfg.max_spread_atr*100.0);
         tag="spread too wide relative to ATR";
         return(false);
        }
     }
   reason="";
   return(true);
  }

//+------------------------------------------------------------------+
bool CRrFilters::ScheduleOk(const datetime now,string &reason,string &tag) const
  {
   if(!WeekdayAllowed(now))
     {
      reason="weekday disabled";
      tag="weekday disabled";
      return(false);
     }
   if(!m_sessions.IsEmpty() && !m_sessions.Contains(now))
     {
      reason="outside trading session";
      tag="outside InpSessions window";
      return(false);
     }
   if(m_blackout.Contains(now))
     {
      reason="inside a blackout window";
      tag="inside InpBlackout window";
      return(false);
     }
   if(FridayFlatten(now))
     {
      reason="past the Friday cut-off";
      tag="past the Friday cut-off";
      return(false);
     }
   reason="";
   return(true);
  }

//+------------------------------------------------------------------+
bool CRrFilters::CooldownOk(const datetime now,string &reason,string &tag) const
  {
   if(m_cfg.cooldown_seconds<=0 || m_last_entry==0)
     {
      reason="";
      return(true);
     }
   int elapsed=(int)(now-m_last_entry);
   if(elapsed<m_cfg.cooldown_seconds)
     {
      reason=StringFormat("cooldown %ds/%ds",elapsed,m_cfg.cooldown_seconds);
      tag="entry cooldown";
      return(false);
     }
   reason="";
   return(true);
  }

//+------------------------------------------------------------------+
//| True once Friday passes the configured hour - the EA stops       |
//| entering and the caller closes whatever is still open, so no     |
//| position carries the weekend gap.                                |
//+------------------------------------------------------------------+
bool CRrFilters::FridayFlatten(const datetime now) const
  {
   if(m_cfg.friday_close_hour<0)
      return(false);

   MqlDateTime dt;
   TimeToStruct(now,dt);
   return(dt.day_of_week==5 && dt.hour>=m_cfg.friday_close_hour);
  }

//+------------------------------------------------------------------+
bool CRrFilters::CanEnter(const datetime now,const double atr,string &reason,string &tag) const
  {
   if(!ScheduleOk(now,reason,tag))
      return(false);
   if(!CooldownOk(now,reason,tag))
      return(false);
   if(!SpreadOk(atr,reason,tag))
      return(false);
   reason="";
   tag="";
   return(true);
  }

//+------------------------------------------------------------------+
//| Minutes on the given weekday where the broker quotes the symbol   |
//| AND the configured session windows allow trading. Returns -1 when |
//| the broker publishes no session table for that day.               |
//+------------------------------------------------------------------+
int CRrFilters::OverlapMinutes(const string symbol,const int day_of_week) const
  {
   bool open_minute[1440];
   for(int i=0;i<1440;i++)
      open_minute[i]=false;

   datetime from,to;
   bool     any=false;

   for(int idx=0;SymbolInfoSessionTrade(symbol,(ENUM_DAY_OF_WEEK)day_of_week,idx,from,to);idx++)
     {
      any=true;
      int a=(int)(from/60);
      int b=(int)(to/60);
      if(a<0)    a=0;
      if(b>1440) b=1440;
      for(int m=a;m<b;m++)
         open_minute[m]=true;
     }

   if(!any)
      return(-1);

   int overlap=0;
   for(int m=0;m<1440;m++)
     {
      if(!open_minute[m])
         continue;
      if(m_sessions.IsEmpty() || m_sessions.ContainsMinute(m))
         overlap++;
     }
   return(overlap);
  }

//+------------------------------------------------------------------+
//| Prints, per weekday, how many minutes are actually tradable. A    |
//| zero here is the whole explanation for a run that took no trades. |
//+------------------------------------------------------------------+
void CRrFilters::ReportSessionOverlap(const string symbol) const
  {
   string names[6]={"","Mon","Tue","Wed","Thu","Fri"};
   bool   enabled[6];
   enabled[0]=false;
   enabled[1]=m_cfg.trade_monday;
   enabled[2]=m_cfg.trade_tuesday;
   enabled[3]=m_cfg.trade_wednesday;
   enabled[4]=m_cfg.trade_thursday;
   enabled[5]=m_cfg.trade_friday;

   string line="";
   int    total=0;
   bool   unknown=false;

   for(int d=1;d<=5;d++)
     {
      if(!enabled[d])
        {
         line+=StringFormat("%s off  ",names[d]);
         continue;
        }
      int mins=OverlapMinutes(symbol,d);
      if(mins<0)
        {
         unknown=true;
         line+=StringFormat("%s ?  ",names[d]);
         continue;
        }
      total+=mins;
      line+=StringFormat("%s %dm  ",names[d],mins);
     }

   RLog.Report("Tradable minutes per weekday (broker session x InpSessions):");
   RLog.Report("  "+line);

   if(unknown)
      RLog.Report("  ('?' = the broker publishes no session table for that day)");

   if(total==0 && !unknown)
     {
      RLog.Report("");
      RLog.Report("*** InpSessions NEVER overlaps this symbol's trading hours. ***");
      RLog.Report("*** The EA cannot take a single trade with these settings.  ***");
      RLog.Report("InpSessions is in BROKER SERVER TIME, which is often several");
      RLog.Report("hours ahead of the exchange. Set InpSessions to \"\" to let the");
      RLog.Report("broker's own session table do the gating, or shift the windows.");
     }
  }

#endif // RR_FILTERS_MQH
