//+------------------------------------------------------------------+
//|                                                    Dashboard.mqh |
//|   On-chart status panel. Text only, so it costs nothing and      |
//|   leaves no objects behind when the EA is removed.               |
//+------------------------------------------------------------------+
#ifndef TS_DASHBOARD_MQH
#define TS_DASHBOARD_MQH

#include <TrendScalper/Config.mqh>
#include <TrendScalper/SignalEngine.mqh>
#include <TrendScalper/RiskManager.mqh>
#include <TrendScalper/TradeExecutor.mqh>

//+------------------------------------------------------------------+
class CDashboard
  {
private:
   bool              m_enabled;
   datetime          m_last_draw;

public:
                     CDashboard(void): m_enabled(false),m_last_draw(0) {}

   void              Init(const bool enabled) { m_enabled=enabled; }
   void              Clear(void) { if(m_enabled) Comment(""); }

   void              Draw(const SSettings &cfg,const CSymbolCtx &sym,const SSignal &sig,
                          const SRiskState &risk,const SBook &book,const string status)
     {
      if(!m_enabled)
         return;

      //--- redraw at most once a second; the panel is cosmetic
      datetime now=TimeCurrent();
      if(now==m_last_draw)
         return;
      m_last_draw=now;

      string text="";
      StringAdd(text,StringFormat("TrendScalper  |  %s %s  |  magic %I64d\n",
                                  sym.symbol,TsTimeframeName(cfg.entry_tf),cfg.magic));
      StringAdd(text,StringFormat("Trend %s   Bias %s   ADX %.1f   RSI %.1f   ATR %s\n",
                                  TsDirName(sig.trend),TsDirName(sig.bias),
                                  sig.adx,sig.rsi,sym.PriceToString(sig.atr)));
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

#endif // TS_DASHBOARD_MQH
