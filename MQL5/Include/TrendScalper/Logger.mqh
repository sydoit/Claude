//+------------------------------------------------------------------+
//|                                                       Logger.mqh |
//|                          Lightweight leveled logger for the EA.  |
//+------------------------------------------------------------------+
#ifndef TS_LOGGER_MQH
#define TS_LOGGER_MQH

enum ENUM_TS_LOG_LEVEL
  {
   TS_LOG_OFF   = 0,   // Off
   TS_LOG_ERROR = 1,   // Errors only
   TS_LOG_WARN  = 2,   // Errors + warnings
   TS_LOG_INFO  = 3,   // Normal activity
   TS_LOG_DEBUG = 4    // Verbose (slow in the tester)
  };

//+------------------------------------------------------------------+
//| Prefixes every message and suppresses anything above the level.  |
//| In the strategy tester INFO/DEBUG output is throttled because    |
//| Print() is expensive on every tick.                              |
//+------------------------------------------------------------------+
class CLogger
  {
private:
   ENUM_TS_LOG_LEVEL m_level;
   string            m_tag;
   bool              m_in_tester;
   bool              m_tester_verbose;

   void              Emit(const string lvl,const string msg)
     {
      PrintFormat("[%s][%s] %s",m_tag,lvl,msg);
     }

   bool              Allowed(const ENUM_TS_LOG_LEVEL lvl) const
     {
      if(lvl>m_level)
         return(false);
      // Tester runs millions of ticks: keep chatty levels off unless asked.
      if(m_in_tester && !m_tester_verbose && lvl>=TS_LOG_INFO)
         return(false);
      return(true);
     }

public:
                     CLogger(void): m_level(TS_LOG_INFO),m_tag("TS"),
                                    m_in_tester(false),m_tester_verbose(false) {}

   void              Init(const string tag,const ENUM_TS_LOG_LEVEL lvl,const bool tester_verbose)
     {
      m_tag             = tag;
      m_level           = lvl;
      m_tester_verbose  = tester_verbose;
      m_in_tester       = (bool)MQLInfoInteger(MQL_TESTER);
     }

   ENUM_TS_LOG_LEVEL Level(void) const { return(m_level); }

   void              Error(const string msg) { if(Allowed(TS_LOG_ERROR)) Emit("ERR ",msg); }
   void              Warn (const string msg) { if(Allowed(TS_LOG_WARN))  Emit("WARN",msg); }
   void              Info (const string msg) { if(Allowed(TS_LOG_INFO))  Emit("INFO",msg); }
   void              Debug(const string msg) { if(Allowed(TS_LOG_DEBUG)) Emit("DBG ",msg); }
  };

CLogger Log;

#endif // TS_LOGGER_MQH
