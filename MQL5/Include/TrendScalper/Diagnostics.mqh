//+------------------------------------------------------------------+
//|                                                  Diagnostics.mqh |
//|   Tally of why the EA did not trade.                             |
//|                                                                  |
//|   An EA that takes no trades and says nothing is impossible to    |
//|   debug. Every gate that turns an entry down records a short tag  |
//|   here, and the totals are printed at shutdown regardless of the  |
//|   log level - including in the strategy tester.                   |
//+------------------------------------------------------------------+
#ifndef TS_DIAGNOSTICS_MQH
#define TS_DIAGNOSTICS_MQH

#include <TrendScalper/Logger.mqh>

#define TS_DIAG_MAX_TAGS 48

//+------------------------------------------------------------------+
class CDiag
  {
private:
   string            m_tag[];
   long              m_hits[];
   long              m_samples;     // gate samples (one per bar)
   long              m_attempts;    // entry attempts

   int               Find(const string tag) const
     {
      int n=ArraySize(m_tag);
      for(int i=0;i<n;i++)
         if(m_tag[i]==tag)
            return(i);
      return(-1);
     }

public:
                     CDiag(void): m_samples(0),m_attempts(0) {}

   void              Reset(void)
     {
      ArrayResize(m_tag,0);
      ArrayResize(m_hits,0);
      m_samples=0;
      m_attempts=0;
     }

   //--- One sample per bar: why entries were not being considered.
   void              Gate(const string tag)
     {
      m_samples++;
      Add(tag);
     }

   //--- One per entry attempt: what happened when we did try.
   void              Attempt(const string tag)
     {
      m_attempts++;
      Add("> "+tag);
     }

   void              Add(const string tag)
     {
      int idx=Find(tag);
      if(idx>=0)
        {
         m_hits[idx]++;
         return;
        }
      int n=ArraySize(m_tag);
      if(n>=TS_DIAG_MAX_TAGS)      // fixed vocabulary; should never happen
         return;
      ArrayResize(m_tag,n+1);
      ArrayResize(m_hits,n+1);
      m_tag[n]=tag;
      m_hits[n]=1;
     }

   long              Samples(void) const { return(m_samples); }

   //--- Printed unconditionally: this is the output that explains a
   //--- run with no trades, so it must survive any log level.
   void              Report(const string title)
     {
      int n=ArraySize(m_tag);

      Log.Report("---------------------------------------------------------------");
      Log.Report(title);

      if(n==0 || m_samples==0)
        {
         Log.Report("No bars were evaluated at all. The EA never received usable");
         Log.Report("indicator data - check that history is available for both the");
         Log.Report("entry and the trend timeframe over the tested period.");
         Log.Report("---------------------------------------------------------------");
         return;
        }

      //--- order by frequency, most common blocker first
      int order[];
      ArrayResize(order,n);
      for(int i=0;i<n;i++)
         order[i]=i;
      for(int i=0;i<n-1;i++)
         for(int j=i+1;j<n;j++)
            if(m_hits[order[j]]>m_hits[order[i]])
              {
               int t=order[i];
               order[i]=order[j];
               order[j]=t;
              }

      Log.Report(StringFormat("%I64d bars evaluated, %I64d entry attempts",m_samples,m_attempts));
      Log.Report("Reason                                      count     share");

      for(int i=0;i<n;i++)
        {
         int k=order[i];
         double share=(m_samples>0) ? (double)m_hits[k]/(double)m_samples*100.0 : 0.0;
         Log.Report(StringFormat("%-40s %8I64d  %6.2f%%",m_tag[k],m_hits[k],share));
        }

      Log.Report("Lines starting with '>' are entry attempts, not bar samples.");
      Log.Report("---------------------------------------------------------------");
     }
  };

CDiag Diag;

#endif // TS_DIAGNOSTICS_MQH
