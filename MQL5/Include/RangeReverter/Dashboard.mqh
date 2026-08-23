//+------------------------------------------------------------------+
//|                                                    Dashboard.mqh |
//|   On-chart status panel. Text only, so it costs nothing and      |
//|   leaves no objects behind when the EA is removed.               |
//+------------------------------------------------------------------+
#ifndef RR_DASHBOARD_MQH
#define RR_DASHBOARD_MQH

#include <RangeReverter/Config.mqh>
#include <RangeReverter/SignalEngine.mqh>
#include <RangeReverter/RiskManager.mqh>
#include <RangeReverter/TradeExecutor.mqh>

//+------------------------------------------------------------------+
class CRrDashboard
  {
private:
   bool              m_enabled;
   datetime          m_last_draw;

   //--- Where price sits across the band, as a percentage: 0 % is the
   //--- lower band, 50 % the mean, 100 % the upper band.
   static double     BandPosition(const CRrSymbolCtx &sym,const SRrSignal &sig)
     {
      double span=sig.upper-sig.lower;
      if(span<=0.0)
         return(50.0);
      return((sym.Bid()-sig.lower)/span*100.0);
     }

public:
                     CRrDashboard(void): m_enabled(false),m_last_draw(0) {}

   void              Init(const bool enabled) { m_enabled=enabled; }
   void              Clear(void) { if(m_enabled) Comment(""); }

   void              Draw(const SRrSettings &cfg,const CRrSymbolCtx &sym,const SRrSignal &sig,
                          const SRrRiskState &risk,const SRrBook &book,const string status)
     {
      if(!m_enabled)
         return;

      //--- redraw at most once a second; the panel is cosmetic
      datetime now=TimeCurrent();
      if(now==m_last_draw)
         return;
      m_last_draw=now;

      string text="";
      StringAdd(text,StringFormat("RangeReverter  |  %s %s  |  magic %I64d\n",
                                  sym.symbol,RrTimeframeName(cfg.entry_tf),cfg.magic));
      StringAdd(text,StringFormat("Regime %s   ADX %.1f / %.1f   HTF stretch %.2f / %.2f\n",
                                  sig.ranging ? "RANGE" : "trending",
                                  sig.adx,cfg.adx_max,sig.htf_stretch,cfg.htf_flat_atr));
      StringAdd(text,StringFormat("Band %.0f%% (0=low 50=mean 100=high)   RSI %.1f   edge %s   width x%.2f\n",
                                  BandPosition(sym,sig),sig.rsi,
                                  sym.PriceToString(sig.edge),sig.width_ratio));
      StringAdd(text,StringFormat("Spread %.1f pt   Open %d (%s lots)   Open P/L %.2f\n",
                                  sym.SpreadPoints(),book.Count(),
                                  sym.LotsToString(book.Volume()),book.Profit()));
      StringAdd(text,StringFormat("Today %+.2f (%+.2f%%)   Trades %d   Streak -%d   DD %.2f%%\n",
                                  risk.daily_pl,risk.daily_pl_percent,
                                  risk.trades_today,risk.consecutive_losses,risk.drawdown_percent));
      StringAdd(text,StringFormat("Status: %s\n",status));

      Comment(text);
     }
  };

#endif // RR_DASHBOARD_MQH
