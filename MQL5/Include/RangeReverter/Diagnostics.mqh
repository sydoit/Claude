//+------------------------------------------------------------------+
//|                                                  Diagnostics.mqh |
//|   Tally of why the EA did not trade.                             |
//|                                                                  |
//|   An EA that takes no trades and says nothing is impossible to    |
//|   debug. Every gate that turns an entry down records a short tag  |
//|   here, and the totals are printed at shutdown regardless of the  |
//|   log level - including in the strategy tester.                   |
//+------------------------------------------------------------------+
#ifndef RR_DIAGNOSTICS_MQH
#define RR_DIAGNOSTICS_MQH

#include <RangeReverter/Logger.mqh>

#define RR_DIAG_MAX_TAGS 48

//+------------------------------------------------------------------+
class CRrDiag
  {
private:
   string            m_tag[];
   long              m_hits[];
   long              m_samples;     // gate samples (one per bar)
   long              m_attempts;    // entry attempts
   long              m_ticks;       // every OnTick, ready or not
   long              m_warmup;      // ticks where indicator data was unusable
   datetime          m_first_tick;
   datetime          m_last_tick;

   int               Find(const string tag) const
     {
      int n=ArraySize(m_tag);
      for(int i=0;i<n;i++)
         if(m_tag[i]==tag)
            return(i);
      return(-1);
     }

public:
                     CRrDiag(void): m_samples(0),m_attempts(0),m_ticks(0),m_warmup(0),
                                  m_first_tick(0),m_last_tick(0) {}

   void              Reset(void)
     {
      ArrayResize(m_tag,0);
      ArrayResize(m_hits,0);
      m_samples=0;
      m_attempts=0;
      m_ticks=0;
      m_warmup=0;
      m_first_tick=0;
      m_last_tick=0;
     }

   //--- Called on every tick, before anything can reject it. A zero here
   //--- means OnTick never ran at all, which is a completely different
   //--- problem from the EA running and finding nothing to trade.
   void              Tick(const datetime when)
     {
      m_ticks++;
      if(m_first_tick==0)
         m_first_tick=when;
      m_last_tick=when;
     }

   //--- Indicator data was not usable this tick. Counted per tick, not
   //--- per bar: with no usable data there is no bar to key on.
   void              Warmup(const string tag)
     {
      m_warmup++;
      Add(tag=="" ? "no data: unknown" : tag);
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
      if(n>=RR_DIAG_MAX_TAGS)      // fixed vocabulary; should never happen
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
         return("A clip is already open and InpMaxPositions is 1, which is the "
                "default and the safe setting for a mean reverter. Entries resume "
                "when the open clip reaches the mean or its stop.");
      if(StringFind(tag,"points ceiling")>=0)
         return("This broker's spread on this symbol is wider than InpMaxSpreadPoints. "
                "Raise it, or accept that the symbol is too expensive to fade.");
      if(StringFind(tag,"relative to ATR")>=0)
         return("The spread is large compared with the ATR of the entry timeframe. "
                "Raise InpMaxSpreadAtr, or use a slower InpEntryTF where ATR is bigger.");
      if(StringFind(tag,"edge does not cover")>=0)
         return("The trip from the band back to the mean is not worth enough multiples "
                "of the spread to be tradable. This is the single most important gate "
                "in the strategy - it is telling you this symbol/timeframe cannot be "
                "faded profitably at this broker's cost. Use a slower InpEntryTF where "
                "the bands are wider, or lower InpMinEdgeSpreads only if you know why.");
      if(StringFind(tag,"edge below")>=0)
         return("The band-to-mean distance is smaller than InpMinEdgeAtr x ATR, so the "
                "bands are hugging price. Widen InpBandDeviation (try 2.2-2.5), lengthen "
                "InpBandPeriod, or lower InpMinEdgeAtr.");
      if(StringFind(tag,"ADX above")>=0)
         return("The market trended for most of the test - this EA deliberately stands "
                "aside then. Raise InpAdxMax to fade in stronger trends (riskier), or "
                "accept that TrendScalper is the right tool for this period.");
      if(StringFind(tag,"higher timeframe is trending")>=0)
         return("The higher timeframe was directional, so fades were vetoed. Raise "
                "InpHtfFlatAtr to tolerate more slope, or set InpUseHtfFilter to false.");
      if(StringFind(tag,"band being ridden")>=0)
         return("Price kept closing outside the band - that is a trend leg, not an "
                "extreme, and fading it is how mean reverters blow up. Raise "
                "InpMaxRideBars only if you have tested what it costs.");
      if(StringFind(tag,"bar range too violent")>=0)
         return("Candles at the extreme were larger than InpMaxBarAtr x ATR, so the EA "
                "refused to catch the knife. Raise InpMaxBarAtr to fade faster moves.");
      if(StringFind(tag,"RSI")>=0)
         return("Price reached the band but RSI was not stretched with it. Move "
                "InpRsiOversold up (try 35) and InpRsiOverbought down (try 65) to "
                "require less confirmation.");
      if(StringFind(tag,"no touch")>=0 || StringFind(tag,"no rejection")>=0)
         return("The regime was right but price never reached the band. Set "
                "InpEntryMode to EITHER (2), lower InpBandDeviation, or use a faster "
                "InpEntryTF where the bands are touched more often.");
      if(StringFind(tag,"reward/risk")>=0)
         return("The distance to the mean was small against the stop the EA would need. "
                "Lower InpMinRewardRisk, tighten InpStopLossAtr, or raise "
                "InpTargetMidFraction towards 1.0.");
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
                "want more frequent fades.");
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

      string name="RangeReverter_"+safe+"_diagnostics.txt";
      int    h=FileOpen(name,FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);

      if(h==INVALID_HANDLE)
        {
         RLog.Report(StringFormat("Could not write %s (error %d)",name,GetLastError()));
         return;
        }

      for(int i=0;i<ArraySize(out);i++)
         FileWrite(h,out[i]);
      FileClose(h);

      RLog.Report("This report was also saved to:");
      RLog.Report("  "+TerminalInfoString(TERMINAL_COMMONDATA_PATH)+"\\Files\\"+name);
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
      int notes=RLog.TranscriptSize();
      if(notes>0)
        {
         Emit(out,"--- start-up ------------------------------------------------");
         for(int i=0;i<notes;i++)
            Emit(out,RLog.TranscriptLine(i));
         Emit(out,"--- result --------------------------------------------------");
         Emit(out,"");
        }

      Emit(out,StringFormat("Ticks received: %I64d   (%s -> %s)",m_ticks,
                            m_first_tick==0 ? "never" : TimeToString(m_first_tick,TIME_DATE|TIME_MINUTES),
                            m_last_tick==0  ? "never" : TimeToString(m_last_tick,TIME_DATE|TIME_MINUTES)));
      Emit(out,StringFormat("Ticks with unusable indicator data: %I64d",m_warmup));
      Emit(out,"");

      //--- Case 1: OnTick never ran. Nothing about the strategy is at fault.
      if(m_ticks==0)
        {
         Emit(out,"VERDICT: the EA never received a single tick.");
         Emit(out,"");
         Emit(out,"OnTick was never called, so no rule of the strategy ever ran. This");
         Emit(out,"is an environment problem, not a settings problem:");
         Emit(out,"  - In the tester: the chosen date range produced no ticks. Check the");
         Emit(out,"    dates, and that this symbol has history there (View > Symbols >");
         Emit(out,"    the symbol > Bars/Ticks, then Request/Download).");
         Emit(out,"  - On a chart: the market was closed for the whole session, or the");
         Emit(out,"    terminal was not connected.");
         Emit(out,"===============================================================");
         for(int i=0;i<ArraySize(out);i++)
            RLog.Report(out[i]);
         WriteToFile(out);
         return;
        }

      //--- Case 2: ticks arrived but indicator data never became usable.
      if(m_samples==0)
        {
         Emit(out,StringFormat("VERDICT: %I64d ticks arrived, but indicator data was never usable.",m_ticks));
         Emit(out,"");
         Emit(out,"The EA ran, so this is a history problem on one specific series.");
         Emit(out,"The rows below name it - 'no data: X' means X never had enough bars,");
         Emit(out,"'short read: X' means the copy came back incomplete.");
         Emit(out,"");
         Emit(out,"Most often this is the TREND timeframe (InpTrendTF): the tester loads");
         Emit(out,"the entry timeframe automatically but not always the higher one.");
         Emit(out,"Open a chart of that timeframe once to force the download, or set");
         Emit(out,"InpUseHtfFilter to false to take that dependency out entirely.");
         Emit(out,"");
        }

      if(n==0)
        {
         Emit(out,"No reasons were recorded at all.");
         Emit(out,"===============================================================");
         for(int i=0;i<ArraySize(out);i++)
            RLog.Report(out[i]);
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
      double top_share=(m_samples>0) ? (double)m_hits[top]/(double)m_samples*100.0 : 0.0;

      if(m_attempts>0)
         Emit(out,StringFormat("VERDICT: %I64d entry attempts were made.",m_attempts));
      else
         if(m_samples>0)
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
         long   basis=(m_samples>0) ? m_samples : m_ticks;
         double share=(basis>0) ? (double)m_hits[k]/(double)basis*100.0 : 0.0;
         Emit(out,StringFormat("%-40s %8I64d  %6.2f%%",m_tag[k],m_hits[k],share));
        }

      Emit(out,"");
      Emit(out,"Lines starting with '>' are entry attempts, not bar samples.");
      Emit(out,"===============================================================");

      for(int i=0;i<ArraySize(out);i++)
         RLog.Report(out[i]);

      WriteToFile(out);
     }

  };

CRrDiag RDiag;

#endif // RR_DIAGNOSTICS_MQH
