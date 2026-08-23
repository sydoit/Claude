//+------------------------------------------------------------------+
//|                                                       Logger.mqh |
//|                          Lightweight leveled logger for the EA.  |
//+------------------------------------------------------------------+
#ifndef RR_LOGGER_MQH
#define RR_LOGGER_MQH

enum ENUM_RR_LOG_LEVEL
  {
   RR_LOG_OFF   = 0,   // Off
   RR_LOG_ERROR = 1,   // Errors only
   RR_LOG_WARN  = 2,   // Errors + warnings
   RR_LOG_INFO  = 3,   // Normal activity
   RR_LOG_DEBUG = 4    // Verbose (slow in the tester)
  };

//+------------------------------------------------------------------+
//| Prefixes every message and suppresses anything above the level.  |
//| In the strategy tester INFO/DEBUG output is throttled because    |
//| Print() is expensive on every tick.                              |
//+------------------------------------------------------------------+
class CRrLogger
  {
private:
   ENUM_RR_LOG_LEVEL m_level;
   string            m_tag;
   bool              m_in_tester;
   bool              m_tester_verbose;
   string            m_transcript[];      // Report() lines, for the diagnostics file

   void              Emit(const string lvl,const string msg)
     {
      PrintFormat("[%s][%s] %s",m_tag,lvl,msg);
     }

   bool              Allowed(const ENUM_RR_LOG_LEVEL lvl) const
     {
      if(lvl>m_level)
         return(false);
      // Tester runs millions of ticks: keep chatty levels off unless asked.
      if(m_in_tester && !m_tester_verbose && lvl>=RR_LOG_INFO)
         return(false);
      return(true);
     }

public:
                     CRrLogger(void): m_level(RR_LOG_INFO),m_tag("RR"),
                                    m_in_tester(false),m_tester_verbose(false) {}

   void              Init(const string tag,const ENUM_RR_LOG_LEVEL lvl,const bool tester_verbose)
     {
      m_tag             = tag;
      m_level           = lvl;
      m_tester_verbose  = tester_verbose;
      m_in_tester       = (bool)MQLInfoInteger(MQL_TESTER);
     }

   ENUM_RR_LOG_LEVEL Level(void) const { return(m_level); }

   //--- Bypasses the level and the tester throttle. For start-up facts
   //--- and the shutdown tally: output the user must never miss. Every
   //--- line is also kept so the diagnostics file can replay the lot.
   void              Report(const string msg)
     {
      Emit("----",msg);
      int n=ArraySize(m_transcript);
      if(n<300)
        {
         ArrayResize(m_transcript,n+1);
         m_transcript[n]=msg;
        }
     }

   int               TranscriptSize(void) const { return(ArraySize(m_transcript)); }
   string            TranscriptLine(const int i) const
     {
      return(i>=0 && i<ArraySize(m_transcript) ? m_transcript[i] : "");
     }

   void              Error(const string msg) { if(Allowed(RR_LOG_ERROR)) Emit("ERR ",msg); }
   void              Warn (const string msg) { if(Allowed(RR_LOG_WARN))  Emit("WARN",msg); }
   void              Info (const string msg) { if(Allowed(RR_LOG_INFO))  Emit("INFO",msg); }
   void              Debug(const string msg) { if(Allowed(RR_LOG_DEBUG)) Emit("DBG ",msg); }
  };

CRrLogger RLog;

#endif // RR_LOGGER_MQH
