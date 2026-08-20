//+------------------------------------------------------------------+
//|                                                  RiskManager.mqh |
//|   Position sizing and the account-level circuit breakers.        |
//|                                                                  |
//|   Sizing works backwards from the stop: the EA decides what a    |
//|   losing trade may cost, then derives the volume from the stop   |
//|   distance - never the other way round.                          |
//+------------------------------------------------------------------+
#ifndef TS_RISKMANAGER_MQH
#define TS_RISKMANAGER_MQH

#include <TrendScalper/Config.mqh>
#include <TrendScalper/Utils.mqh>

//+------------------------------------------------------------------+
struct SRiskState
  {
   double            day_start_equity;
   double            peak_equity;
   double            daily_pl;            // money, realised + open
   double            daily_pl_percent;
   double            drawdown_percent;    // from the equity peak
   int               trades_today;
   int               consecutive_losses;
   bool              halted;              // a breaker tripped for today
   string            halt_reason;
  };

//+------------------------------------------------------------------+
class CRiskManager
  {
private:
   SSettings         m_cfg;
   CSymbolCtx       *m_sym;
   SRiskState        m_state;
   datetime          m_day;               // midnight of the current server day
   datetime          m_last_scan;

   datetime          DayStart(const datetime t) const
     {
      MqlDateTime dt;
      TimeToStruct(t,dt);
      dt.hour=0;
      dt.min=0;
      dt.sec=0;
      return(StructToTime(dt));
     }

   void              ScanHistory(void);
   double            LossPerLot(const int dir,const double entry,const double stop) const;

public:
                     CRiskManager(void): m_sym(NULL),m_day(0),m_last_scan(0) {}

   bool              Init(const SSettings &cfg,CSymbolCtx *sym);
   void              Refresh(void);                       // call once per tick
   void              OnPositionClosed(void) { m_last_scan=0; }

   bool              TradingAllowed(string &reason);
   double            CalcLots(const int dir,const double entry,const double stop,
                              const double existing_volume,string &reason);

   SRiskState        State(void) const { return(m_state); }
   bool              IsHalted(void) const { return(m_state.halted); }
  };

//+------------------------------------------------------------------+
bool CRiskManager::Init(const SSettings &cfg,CSymbolCtx *sym)
  {
   m_cfg=cfg;
   m_sym=sym;

   double equity=AccountInfoDouble(ACCOUNT_EQUITY);

   m_day                       = DayStart(TimeCurrent());
   m_state.day_start_equity    = equity;
   m_state.peak_equity         = equity;
   m_state.daily_pl            = 0.0;
   m_state.daily_pl_percent    = 0.0;
   m_state.drawdown_percent    = 0.0;
   m_state.trades_today        = 0;
   m_state.consecutive_losses  = 0;
   m_state.halted              = false;
   m_state.halt_reason         = "";
   m_last_scan                 = 0;

   ScanHistory();

   Log.Info(StringFormat("Risk: %.2f%% per trade, daily stop %.2f%%, max positions %d, start equity %.2f",
                         m_cfg.risk_percent,m_cfg.daily_loss_percent,m_cfg.max_positions,equity));
   return(true);
  }

//+------------------------------------------------------------------+
//| Walks today's closed deals for this EA to count entries and the  |
//| current losing streak. Throttled - it is only needed when the    |
//| history actually changes.                                        |
//+------------------------------------------------------------------+
void CRiskManager::ScanHistory(void)
  {
   datetime now=TimeCurrent();
   if(m_last_scan>0 && now-m_last_scan<2)
      return;
   m_last_scan=now;

   m_state.trades_today=0;
   m_state.consecutive_losses=0;

   //--- the streak may reach back before today, so scan a wider window
   datetime from=m_day-30*86400;
   if(!HistorySelect(from,now+60))
     {
      Log.Warn("HistorySelect failed - risk counters may be stale this tick");
      return;
     }

   bool streak_open=true;
   int  total=HistoryDealsTotal();

   for(int i=total-1;i>=0;i--)
     {
      ulong ticket=HistoryDealGetTicket(i);
      if(ticket==0)
         continue;
      if(HistoryDealGetString(ticket,DEAL_SYMBOL)!=m_sym.symbol)
         continue;
      if(HistoryDealGetInteger(ticket,DEAL_MAGIC)!=m_cfg.magic)
         continue;

      long     entry = HistoryDealGetInteger(ticket,DEAL_ENTRY);
      datetime when  = (datetime)HistoryDealGetInteger(ticket,DEAL_TIME);

      if(entry==DEAL_ENTRY_IN && when>=m_day)
         m_state.trades_today++;

      if(streak_open && (entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY))
        {
         double net=HistoryDealGetDouble(ticket,DEAL_PROFIT)+
                    HistoryDealGetDouble(ticket,DEAL_SWAP)+
                    HistoryDealGetDouble(ticket,DEAL_COMMISSION);
         if(net<0.0)
            m_state.consecutive_losses++;
         else
            if(net>0.0)
               streak_open=false;      // a winner ends the streak; scratches are skipped
        }
     }
  }

//+------------------------------------------------------------------+
void CRiskManager::Refresh(void)
  {
   datetime today=DayStart(TimeCurrent());
   double   equity=AccountInfoDouble(ACCOUNT_EQUITY);

   if(today!=m_day)
     {
      m_day                    = today;
      m_state.day_start_equity = equity;
      m_state.halted           = false;
      m_state.halt_reason      = "";
      m_last_scan              = 0;
      Log.Info(StringFormat("New trading day - counters reset, equity %.2f",equity));
     }

   if(equity>m_state.peak_equity)
      m_state.peak_equity=equity;

   m_state.daily_pl=equity-m_state.day_start_equity;
   m_state.daily_pl_percent=(m_state.day_start_equity>0.0)
                            ? m_state.daily_pl/m_state.day_start_equity*100.0 : 0.0;
   m_state.drawdown_percent=(m_state.peak_equity>0.0)
                            ? (m_state.peak_equity-equity)/m_state.peak_equity*100.0 : 0.0;

   ScanHistory();
  }

//+------------------------------------------------------------------+
//| Every breaker that can stop new entries. Open positions are      |
//| still managed normally when this returns false.                  |
//+------------------------------------------------------------------+
bool CRiskManager::TradingAllowed(string &reason)
  {
   if(m_state.halted)
     {
      reason=m_state.halt_reason;
      return(false);
     }

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
     {
      reason="algo trading disabled in the terminal";
      return(false);
     }
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT) || !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
     {
      reason="trading not permitted on this account";
      return(false);
     }
   long trade_mode=SymbolInfoInteger(m_sym.symbol,SYMBOL_TRADE_MODE);
   if(trade_mode==SYMBOL_TRADE_MODE_DISABLED || trade_mode==SYMBOL_TRADE_MODE_CLOSEONLY)
     {
      reason="symbol is closed for new positions";
      return(false);
     }

   if(m_cfg.daily_loss_percent>0.0 && m_state.daily_pl_percent<=-m_cfg.daily_loss_percent)
     {
      m_state.halted=true;
      m_state.halt_reason=StringFormat("daily loss limit hit (%.2f%%)",m_state.daily_pl_percent);
      Log.Warn("Halting new entries for today: "+m_state.halt_reason);
      reason=m_state.halt_reason;
      return(false);
     }
   if(m_cfg.daily_profit_percent>0.0 && m_state.daily_pl_percent>=m_cfg.daily_profit_percent)
     {
      m_state.halted=true;
      m_state.halt_reason=StringFormat("daily profit target reached (%.2f%%)",m_state.daily_pl_percent);
      Log.Info("Halting new entries for today: "+m_state.halt_reason);
      reason=m_state.halt_reason;
      return(false);
     }
   if(m_cfg.max_drawdown_percent>0.0 && m_state.drawdown_percent>=m_cfg.max_drawdown_percent)
     {
      m_state.halted=true;
      m_state.halt_reason=StringFormat("equity drawdown %.2f%% exceeded the %.2f%% limit",
                                       m_state.drawdown_percent,m_cfg.max_drawdown_percent);
      Log.Warn("Halting new entries: "+m_state.halt_reason);
      reason=m_state.halt_reason;
      return(false);
     }
   if(m_cfg.max_consecutive_losses>0 && m_state.consecutive_losses>=m_cfg.max_consecutive_losses)
     {
      reason=StringFormat("%d consecutive losses",m_state.consecutive_losses);
      return(false);
     }
   if(m_cfg.max_trades_per_day>0 && m_state.trades_today>=m_cfg.max_trades_per_day)
     {
      reason=StringFormat("daily trade cap reached (%d)",m_state.trades_today);
      return(false);
     }

   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double free_margin=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(m_cfg.min_free_margin_percent>0.0 && equity>0.0 &&
      free_margin/equity*100.0<m_cfg.min_free_margin_percent)
     {
      reason=StringFormat("free margin %.1f%% below the %.1f%% floor",
                          free_margin/equity*100.0,m_cfg.min_free_margin_percent);
      return(false);
     }

   reason="";
   return(true);
  }

//+------------------------------------------------------------------+
//| Money lost per 1.0 lot if the stop is hit. OrderCalcProfit knows |
//| the contract size and the currency conversion, so prefer it and  |
//| only fall back to tick arithmetic if the call fails.             |
//+------------------------------------------------------------------+
double CRiskManager::LossPerLot(const int dir,const double entry,const double stop) const
  {
   double profit=0.0;
   ENUM_ORDER_TYPE type=(dir>0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   if(OrderCalcProfit(type,m_sym.symbol,1.0,entry,stop,profit) && MathAbs(profit)>0.0)
      return(MathAbs(profit));

   if(m_sym.tick_size>0.0 && m_sym.tick_value>0.0)
      return(MathAbs(entry-stop)/m_sym.tick_size*m_sym.tick_value);

   return(0.0);
  }

//+------------------------------------------------------------------+
//| Volume for the next clip. Returns 0 with a reason when the trade |
//| cannot be sized safely.                                          |
//+------------------------------------------------------------------+
double CRiskManager::CalcLots(const int dir,const double entry,const double stop,
                              const double existing_volume,string &reason)
  {
   reason="";

   double lots=0.0;

   if(m_cfg.lot_mode==TS_LOT_FIXED)
      lots=m_cfg.fixed_lots;
   else
     {
      double equity=AccountInfoDouble(ACCOUNT_EQUITY);
      double budget=equity*m_cfg.risk_percent/100.0;
      double per_lot=LossPerLot(dir,entry,stop);

      if(per_lot<=0.0)
        {
         reason="cannot value the stop distance for this symbol";
         return(0.0);
        }
      lots=budget/per_lot;
     }

   if(m_cfg.max_lots>0.0)
      lots=MathMin(lots,m_cfg.max_lots);

   //--- keep total exposure under the ceiling, counting what is already open
   if(m_cfg.max_total_lots>0.0)
     {
      double headroom=m_cfg.max_total_lots-existing_volume;
      if(headroom<=0.0)
        {
         reason=StringFormat("total exposure cap reached (%s lots open)",m_sym.LotsToString(existing_volume));
         return(0.0);
        }
      lots=MathMin(lots,headroom);
     }

   lots=m_sym.FloorLots(lots);

   if(!m_sym.LotsTradable(lots))
     {
      reason=StringFormat("sized volume %s is below the %s minimum - risk budget too small for this stop",
                          m_sym.LotsToString(lots),m_sym.LotsToString(m_sym.vol_min));
      return(0.0);
     }

   //--- final margin check with the real broker formula
   double margin=0.0;
   ENUM_ORDER_TYPE type=(dir>0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(OrderCalcMargin(type,m_sym.symbol,lots,entry,margin))
     {
      double free_margin=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      if(margin>free_margin)
        {
         reason=StringFormat("margin %.2f exceeds free margin %.2f",margin,free_margin);
         return(0.0);
        }
     }

   return(lots);
  }

#endif // TS_RISKMANAGER_MQH
