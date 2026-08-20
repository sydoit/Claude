//+------------------------------------------------------------------+
//|                                                      Filters.mqh |
//|   Cheap "should we even look at a signal right now" checks:      |
//|   trading sessions, news blackouts, weekday rules, spread and    |
//|   the entry cooldown.                                            |
//+------------------------------------------------------------------+
#ifndef TS_FILTERS_MQH
#define TS_FILTERS_MQH

#include <TrendScalper/Config.mqh>
#include <TrendScalper/Utils.mqh>

//+------------------------------------------------------------------+
class CFilters
  {
private:
   SSettings         m_cfg;
   CSymbolCtx       *m_sym;
   CTimeWindows      m_sessions;
   CTimeWindows      m_blackout;
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
                     CFilters(void): m_sym(NULL),m_last_entry(0) {}

   bool              Init(const SSettings &cfg,CSymbolCtx *sym);

   void              NoteEntry(const datetime when) { m_last_entry=when; }

   bool              SpreadOk(const double atr,string &reason) const;
   bool              ScheduleOk(const datetime now,string &reason) const;
   bool              CooldownOk(const datetime now,string &reason) const;
   bool              FridayFlatten(const datetime now) const;
   bool              CanEnter(const datetime now,const double atr,string &reason) const;
  };

//+------------------------------------------------------------------+
bool CFilters::Init(const SSettings &cfg,CSymbolCtx *sym)
  {
   m_cfg=cfg;
   m_sym=sym;

   if(!m_sessions.Parse(m_cfg.sessions))
      return(false);
   if(!m_blackout.Parse(m_cfg.blackout))
      return(false);

   Log.Info(StringFormat("Schedule: sessions [%s] blackout [%s] (server time)",
                         m_cfg.sessions=="" ? "24h" : m_cfg.sessions,
                         m_cfg.blackout=="" ? "none" : m_cfg.blackout));
   return(true);
  }

//+------------------------------------------------------------------+
//| Two ceilings: an absolute one in points and a relative one as a  |
//| fraction of ATR. The relative one keeps the EA honest when       |
//| volatility collapses and the spread quietly eats the edge.       |
//+------------------------------------------------------------------+
bool CFilters::SpreadOk(const double atr,string &reason) const
  {
   double spread_points=m_sym.SpreadPoints();

   if(m_cfg.max_spread_points>0.0 && spread_points>m_cfg.max_spread_points)
     {
      reason=StringFormat("spread %.1fpt above the %.1fpt ceiling",spread_points,m_cfg.max_spread_points);
      return(false);
     }
   if(m_cfg.max_spread_atr>0.0 && atr>0.0)
     {
      double spread=m_sym.Spread();
      if(spread>atr*m_cfg.max_spread_atr)
        {
         reason=StringFormat("spread is %.0f%% of ATR (limit %.0f%%)",
                             spread/atr*100.0,m_cfg.max_spread_atr*100.0);
         return(false);
        }
     }
   reason="";
   return(true);
  }

//+------------------------------------------------------------------+
bool CFilters::ScheduleOk(const datetime now,string &reason) const
  {
   if(!WeekdayAllowed(now))
     {
      reason="weekday disabled";
      return(false);
     }
   if(!m_sessions.IsEmpty() && !m_sessions.Contains(now))
     {
      reason="outside trading session";
      return(false);
     }
   if(m_blackout.Contains(now))
     {
      reason="inside a blackout window";
      return(false);
     }
   if(FridayFlatten(now))
     {
      reason="past the Friday cut-off";
      return(false);
     }
   reason="";
   return(true);
  }

//+------------------------------------------------------------------+
bool CFilters::CooldownOk(const datetime now,string &reason) const
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
bool CFilters::FridayFlatten(const datetime now) const
  {
   if(m_cfg.friday_close_hour<0)
      return(false);

   MqlDateTime dt;
   TimeToStruct(now,dt);
   return(dt.day_of_week==5 && dt.hour>=m_cfg.friday_close_hour);
  }

//+------------------------------------------------------------------+
bool CFilters::CanEnter(const datetime now,const double atr,string &reason) const
  {
   if(!ScheduleOk(now,reason))
      return(false);
   if(!CooldownOk(now,reason))
      return(false);
   if(!SpreadOk(atr,reason))
      return(false);
   reason="";
   return(true);
  }

#endif // TS_FILTERS_MQH
