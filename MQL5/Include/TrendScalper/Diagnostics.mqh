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

   //--- Plain-English fix for the gate that blocked the most bars.
   static string    Remedy(const string tag)
     {
      if(StringFind(tag,"InpSessions window")>=0)
         return("InpSessions never opens while this symbol is quoted. It is in "
                "BROKER SERVER TIME. Clear it to blank and let the broker's own "
                "session table gate trading.");
      if(StringFind(tag,"below broker minimum")>=0)
         return("The risk budget cannot afford one minimum lot at this stop distance. "
                "Raise InpRiskPercent, fund the account higher, set InpMaxLots to 0, "
                "or trade a lower-priced instrument.");
      if(StringFind(tag,"InpMaxTotalLots")>=0)
         return("InpMaxTotalLots is too small for this symbol's volume units. "
                "Set it to 0 (no cap) and let InpRiskPercent size the trade.");
      if(StringFind(tag,"InpMaxPositions")>=0)
         return("The book is full. Positions are not closing - check the exit settings "
                "(InpMaxHoldSeconds, InpExitOnFlip) rather than the entry rules.");
      if(StringFind(tag,"points ceiling")>=0)
         return("This broker's spread on this symbol is wider than InpMaxSpreadPoints. "
                "Raise it, or accept that the symbol is too expensive to scalp.");
      if(StringFind(tag,"relative to ATR")>=0)
         return("The spread is large compared with the ATR of the entry timeframe. "
                "Raise InpMaxSpreadAtr, or use a slower InpEntryTF where ATR is bigger. "
                "If it will not pass at any sane setting, this symbol cannot be scalped "
                "profitably on this account.");
      if(StringFind(tag,"ADX")>=0)
         return("The market rarely trended by this measure. Lower InpAdxMin (try 15-18) "
                "or use a slower entry timeframe.");
      if(StringFind(tag,"higher timeframe disagrees")>=0)
         return("The trend timeframe rarely agreed with the entry timeframe. Try a "
                "closer InpTrendTF, or set InpUseHtfFilter to false.");
      if(StringFind(tag,"RSI")>=0)
         return("The RSI band is too narrow. Widen InpRsiBuyMin/Max and InpRsiSellMin/Max.");
      if(StringFind(tag,"no trigger")>=0)
         return("Trend filters passed but no entry fired. Set InpEntryMode to EITHER (2), "
                "raise InpBreakoutLookback, or loosen InpPullbackDepthAtr.");
      if(StringFind(tag,"no trend")>=0)
         return("The EMA stack and slope rarely lined up. This is normal in a range; if "
                "it is nearly every bar, try a slower InpEntryTF.");
      if(StringFind(tag,"warm-up")>=0)
         return("Indicator data never became usable. Download history for BOTH the entry "
                "and the trend timeframe, and check the tested date range has bars.");
      if(StringFind(tag,"weekday")>=0)
         return("Every weekday you tested is switched off in the InpTrade* inputs.");
      if(StringFind(tag,"algo trading disabled")>=0)
         return("Enable the terminal's Algo Trading button and tick Allow Algo Trading "
                "on the EA's Common tab.");
      if(StringFind(tag,"symbol closed")>=0)
         return("The broker has this symbol closed for new positions.");
      if(StringFind(tag,"breaker")>=0 || StringFind(tag,"limit")>=0 ||
         StringFind(tag,"cap")>=0)
         return("A risk breaker stopped trading. This is the EA working as configured, "
                "not a fault - loosen the guard if it is firing too early.");
      if(StringFind(tag,"cooldown")>=0)
         return("Entries were mostly waiting out InpCooldownSeconds. Lower it if you "
                "want more frequent clips.");
      if(StringFind(tag,"reached the entry check")>=0)
         return("Every gate passed on these bars - the entry rules simply did not fire. "
                "This is a strategy result, not a configuration fault.");
      return("");
     }

   void              Emit(string &out[],const string line)
     {
      int n=ArraySize(out);
      ArrayResize(out,n+1);
      out[n]=line;
     }

   //--- Also written to a text file so the report can be read without
   //--- digging through the Journal tab. FILE_COMMON keeps live runs and
   //--- tester agents writing to the same predictable folder.
   void              WriteToFile(const string &out[])
     {
      string safe="";
      for(int i=0;i<StringLen(_Symbol);i++)
        {
         ushort c=StringGetCharacter(_Symbol,i);
         bool alnum=((c>='0' && c<='9') || (c>='A' && c<='Z') || (c>='a' && c<='z'));
         safe+=alnum ? ShortToString(c) : "_";
        }

      string name="TrendScalper_"+safe+"_diagnostics.txt";
      int    h=FileOpen(name,FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);

      if(h==INVALID_HANDLE)
        {
         Log.Report(StringFormat("Could not write %s (error %d)",name,GetLastError()));
         return;
        }

      for(int i=0;i<ArraySize(out);i++)
         FileWrite(h,out[i]);
      FileClose(h);

      Log.Report("This report was also saved to:");
      Log.Report("  "+TerminalInfoString(TERMINAL_COMMONDATA_PATH)+"\\Files\\"+name);
     }

   //--- Printed unconditionally: this is the output that explains a
   //--- run with no trades, so it must survive any log level.
   void              Report(const string title)
     {
      int    n=ArraySize(m_tag);
      string out[];
      ArrayResize(out,0);

      Emit(out,"===============================================================");
      Emit(out,title);
      Emit(out,StringFormat("Symbol %s, finished %s",_Symbol,
                            TimeToString(TimeCurrent(),TIME_DATE|TIME_MINUTES)));
      Emit(out,"");

      //--- replay what was printed at start-up, so the file is self-contained
      int notes=Log.TranscriptSize();
      if(notes>0)
        {
         Emit(out,"--- start-up ------------------------------------------------");
         for(int i=0;i<notes;i++)
            Emit(out,Log.TranscriptLine(i));
         Emit(out,"--- result --------------------------------------------------");
         Emit(out,"");
        }

      if(n==0 || m_samples==0)
        {
         Emit(out,"VERDICT: no bars were evaluated at all.");
         Emit(out,"");
         Emit(out,"The EA never received usable indicator data, so it never reached");
         Emit(out,"the entry rules. Check, in this order:");
         Emit(out,"  1. History exists for the tested range on the ENTRY timeframe.");
         Emit(out,"  2. History exists on the TREND timeframe too (InpTrendTF).");
         Emit(out,"  3. The tested date range actually contains bars for this symbol.");
         Emit(out,"===============================================================");
         for(int i=0;i<ArraySize(out);i++)
            Log.Report(out[i]);
         WriteToFile(out);
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

      //--- the verdict: name the top blocker and what to do about it
      int    top=order[0];
      double top_share=(double)m_hits[top]/(double)m_samples*100.0;

      if(m_attempts>0)
         Emit(out,StringFormat("VERDICT: %I64d entry attempts were made.",m_attempts));
      else
        {
         Emit(out,"VERDICT: no entry was ever attempted.");
         Emit(out,"");
         Emit(out,StringFormat("The gate that blocked the most bars (%.1f%% of them) was:",top_share));
         Emit(out,"  "+m_tag[top]);
         string fix=Remedy(m_tag[top]);
         if(fix!="")
           {
            Emit(out,"");
            Emit(out,"  "+fix);
           }
        }

      Emit(out,"");
      Emit(out,StringFormat("%I64d bars evaluated, %I64d entry attempts",m_samples,m_attempts));
      Emit(out,"");
      Emit(out,"Reason                                      count     share");

      for(int i=0;i<n;i++)
        {
         int k=order[i];
         double share=(double)m_hits[k]/(double)m_samples*100.0;
         Emit(out,StringFormat("%-40s %8I64d  %6.2f%%",m_tag[k],m_hits[k],share));
        }

      Emit(out,"");
      Emit(out,"Lines starting with '>' are entry attempts, not bar samples.");
      Emit(out,"===============================================================");

      for(int i=0;i<ArraySize(out);i++)
         Log.Report(out[i]);

      WriteToFile(out);
     }

  };

CDiag Diag;

#endif // TS_DIAGNOSTICS_MQH
