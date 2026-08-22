//+------------------------------------------------------------------+
//|                                                TradeExecutor.mqh |
//|   Order placement and the life-cycle of every open clip:         |
//|   break-even, partial profit, trailing, time and flip exits.     |
//+------------------------------------------------------------------+
#ifndef TS_TRADEEXECUTOR_MQH
#define TS_TRADEEXECUTOR_MQH

#include <Trade\Trade.mqh>
#include <TrendScalper/Config.mqh>
#include <TrendScalper/Utils.mqh>
#include <TrendScalper/SignalEngine.mqh>
#include <TrendScalper/RiskManager.mqh>

//+------------------------------------------------------------------+
//| Aggregated view of what this EA currently holds on the symbol.   |
//+------------------------------------------------------------------+
struct SBook
  {
   int               count_buy;
   int               count_sell;
   double            volume_buy;
   double            volume_sell;
   double            profit_buy;
   double            profit_sell;
   double            best_buy_entry;    // highest long entry seen
   double            best_sell_entry;   // lowest short entry seen
   datetime          newest_entry;

   int               Count(void)  const { return(count_buy+count_sell);   }
   double            Volume(void) const { return(volume_buy+volume_sell); }
   double            Profit(void) const { return(profit_buy+profit_sell); }
  };

//+------------------------------------------------------------------+
class CTradeExecutor
  {
private:
   SSettings         m_cfg;
   CSymbolCtx       *m_sym;
   CRiskManager     *m_risk;
   CTrade            m_trade;
   SBook             m_book;
   bool              m_hedging;
   ulong             m_partial_done[];   // tickets whose partial has been taken

   bool              IsRetryable(const uint code) const;
   bool              SendMarket(const int dir,const double lots,const double sl,const double tp,
                                const string why);
   bool              ModifyStops(const ulong ticket,const double sl,const double tp);
   bool              PartialTaken(const ulong ticket) const;
   void              MarkPartial(const ulong ticket);
   void              PrunePartials(void);
   double            ClampStop(const int dir,const double price,const double raw_sl) const;
   double            ClampTarget(const int dir,const double price,const double raw_tp) const;
   bool              ManageOne(const ulong ticket,const SSignal &sig,const bool force_close,
                               const string force_reason);

public:
                     CTradeExecutor(void): m_sym(NULL),m_risk(NULL),m_hedging(true) {}

   bool              Init(const SSettings &cfg,CSymbolCtx *sym,CRiskManager *risk);

   void              RefreshBook(void);
   SBook             Book(void) const { return(m_book); }
   bool              IsHedging(void) const { return(m_hedging); }

   bool              CanStack(const int dir,const double atr,string &reason,string &tag) const;
   bool              TryEnter(const SSignal &sig,string &reason,string &tag);
   void              ManageOpen(const SSignal &sig,const bool flatten_all,const string flatten_reason);
   int               CloseDirection(const int dir,const string why);
   int               CloseAll(const string why);
  };

//+------------------------------------------------------------------+
bool CTradeExecutor::Init(const SSettings &cfg,CSymbolCtx *sym,CRiskManager *risk)
  {
   m_cfg  = cfg;
   m_sym  = sym;
   m_risk = risk;

   m_hedging=(ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING;

   m_trade.SetExpertMagicNumber((ulong)m_cfg.magic);
   m_trade.SetDeviationInPoints((ulong)MathMax(1,m_cfg.max_slippage_points));
   m_trade.SetTypeFillingBySymbol(m_sym.symbol);
   m_trade.SetAsyncMode(false);
   m_trade.LogLevel((ENUM_LOG_LEVELS)(Log.Level()>=TS_LOG_DEBUG ? LOG_LEVEL_ALL : LOG_LEVEL_ERRORS));

   ArrayResize(m_partial_done,0);

   if(!m_hedging)
      Log.Warn("Netting account detected - stacked clips merge into one position, "
               "so per-clip stops and partial closes apply to the merged position");

   Log.Info(StringFormat("Execution: magic %I64d, slippage %dpt, %s account",
                         m_cfg.magic,m_cfg.max_slippage_points,m_hedging ? "hedging" : "netting"));
   return(true);
  }

//+------------------------------------------------------------------+
void CTradeExecutor::RefreshBook(void)
  {
   m_book.count_buy       = 0;
   m_book.count_sell      = 0;
   m_book.volume_buy      = 0.0;
   m_book.volume_sell     = 0.0;
   m_book.profit_buy      = 0.0;
   m_book.profit_sell     = 0.0;
   m_book.best_buy_entry  = 0.0;
   m_book.best_sell_entry = 0.0;
   m_book.newest_entry    = 0;

   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0)
         continue;
      if(PositionGetString(POSITION_SYMBOL)!=m_sym.symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC)!=m_cfg.magic)
         continue;

      long     type   = PositionGetInteger(POSITION_TYPE);
      double   volume = PositionGetDouble(POSITION_VOLUME);
      double   price  = PositionGetDouble(POSITION_PRICE_OPEN);
      double   profit = PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      datetime opened = (datetime)PositionGetInteger(POSITION_TIME);

      if(opened>m_book.newest_entry)
         m_book.newest_entry=opened;

      if(type==POSITION_TYPE_BUY)
        {
         m_book.count_buy++;
         m_book.volume_buy+=volume;
         m_book.profit_buy+=profit;
         if(m_book.best_buy_entry==0.0 || price>m_book.best_buy_entry)
            m_book.best_buy_entry=price;
        }
      else
        {
         m_book.count_sell++;
         m_book.volume_sell+=volume;
         m_book.profit_sell+=profit;
         if(m_book.best_sell_entry==0.0 || price<m_book.best_sell_entry)
            m_book.best_sell_entry=price;
        }
     }

   PrunePartials();
  }

//+------------------------------------------------------------------+
bool CTradeExecutor::IsRetryable(const uint code) const
  {
   return(code==TRADE_RETCODE_REQUOTE       ||
          code==TRADE_RETCODE_PRICE_CHANGED ||
          code==TRADE_RETCODE_PRICE_OFF     ||
          code==TRADE_RETCODE_TIMEOUT       ||
          code==TRADE_RETCODE_CONNECTION    ||
          code==TRADE_RETCODE_TOO_MANY_REQUESTS);
  }

//+------------------------------------------------------------------+
//| Keeps the stop the required distance from the market. A stop too |
//| close is rejected outright by the server, which on a scalper     |
//| means an unprotected position, so we widen instead of failing.   |
//+------------------------------------------------------------------+
double CTradeExecutor::ClampStop(const int dir,const double price,const double raw_sl) const
  {
   double min_dist=m_sym.MinStopDistance();
   double sl=raw_sl;

   if(dir>0)
     {
      if(price-sl<min_dist)
         sl=price-min_dist;
     }
   else
     {
      if(sl-price<min_dist)
         sl=price+min_dist;
     }
   return(m_sym.NormalizePrice(sl));
  }

//+------------------------------------------------------------------+
double CTradeExecutor::ClampTarget(const int dir,const double price,const double raw_tp) const
  {
   if(raw_tp<=0.0)
      return(0.0);

   double min_dist=m_sym.MinStopDistance();
   double tp=raw_tp;

   if(dir>0)
     {
      if(tp-price<min_dist)
         tp=price+min_dist;
     }
   else
     {
      if(price-tp<min_dist)
         tp=price-min_dist;
     }
   return(m_sym.NormalizePrice(tp));
  }

//+------------------------------------------------------------------+
//| Market order with bounded retries. Prices are re-read on every   |
//| attempt so a requote does not resend a stale level.              |
//+------------------------------------------------------------------+
bool CTradeExecutor::SendMarket(const int dir,const double lots,const double sl,const double tp,
                                const string why)
  {
   int attempts=MathMax(1,m_cfg.order_retries);

   for(int attempt=1;attempt<=attempts;attempt++)
     {
      m_sym.RefreshLevels();

      double price = (dir>0) ? m_sym.Ask() : m_sym.Bid();
      if(price<=0.0)
        {
         Log.Warn("No price available - skipping this attempt");
         continue;
        }

      double use_sl = ClampStop(dir,price,sl);
      double use_tp = ClampTarget(dir,price,tp);

      bool sent = (dir>0)
                  ? m_trade.Buy(lots,m_sym.symbol,price,use_sl,use_tp,m_cfg.trade_comment)
                  : m_trade.Sell(lots,m_sym.symbol,price,use_sl,use_tp,m_cfg.trade_comment);

      uint code=m_trade.ResultRetcode();

      if(sent && (code==TRADE_RETCODE_DONE || code==TRADE_RETCODE_PLACED ||
                  code==TRADE_RETCODE_DONE_PARTIAL))
        {
         Log.Info(StringFormat("%s %s @ %s SL %s TP %s (%s)",
                               TsDirName(dir),m_sym.LotsToString(m_trade.ResultVolume()),
                               m_sym.PriceToString(m_trade.ResultPrice()),
                               m_sym.PriceToString(use_sl),
                               use_tp>0.0 ? m_sym.PriceToString(use_tp) : "-",
                               why));
         return(true);
        }

      Log.Warn(StringFormat("Order attempt %d/%d failed: %u %s",
                            attempt,attempts,code,m_trade.ResultRetcodeDescription()));

      if(!IsRetryable(code))
         return(false);

      //--- give the server a moment before re-pricing (a no-op in the tester)
      if(attempt<attempts)
         Sleep(100);
     }

   return(false);
  }

//+------------------------------------------------------------------+
bool CTradeExecutor::ModifyStops(const ulong ticket,const double sl,const double tp)
  {
   if(!PositionSelectByTicket(ticket))
      return(false);

   //--- a position whose stop or target sits inside the freeze band
   //--- cannot be modified at all, so do not waste an order on it
   double freeze=m_sym.FreezeDistance();
   if(freeze>0.0)
     {
      long   type   = PositionGetInteger(POSITION_TYPE);
      double price  = (type==POSITION_TYPE_BUY) ? m_sym.Bid() : m_sym.Ask();
      double cur_sl = PositionGetDouble(POSITION_SL);
      double cur_tp = PositionGetDouble(POSITION_TP);
      if((cur_tp>0.0 && MathAbs(cur_tp-price)<freeze) ||
         (cur_sl>0.0 && MathAbs(cur_sl-price)<freeze))
        {
         Log.Debug(StringFormat("Ticket %I64u is inside the freeze level - stop update deferred",ticket));
         return(false);
        }
     }

   if(m_trade.PositionModify(ticket,sl,tp))
      return(true);

   uint code=m_trade.ResultRetcode();
   if(code!=TRADE_RETCODE_NO_CHANGES)
      Log.Warn(StringFormat("Stop update on %I64u failed: %u %s",
                            ticket,code,m_trade.ResultRetcodeDescription()));
   return(false);
  }

//+------------------------------------------------------------------+
bool CTradeExecutor::PartialTaken(const ulong ticket) const
  {
   int n=ArraySize(m_partial_done);
   for(int i=0;i<n;i++)
      if(m_partial_done[i]==ticket)
         return(true);
   return(false);
  }

//+------------------------------------------------------------------+
void CTradeExecutor::MarkPartial(const ulong ticket)
  {
   int n=ArraySize(m_partial_done);
   ArrayResize(m_partial_done,n+1);
   m_partial_done[n]=ticket;
  }

//+------------------------------------------------------------------+
//| Drops tickets that are no longer open so the list cannot grow    |
//| without bound over a long run.                                   |
//+------------------------------------------------------------------+
void CTradeExecutor::PrunePartials(void)
  {
   int n=ArraySize(m_partial_done);
   if(n==0)
      return;

   ulong kept[];
   ArrayResize(kept,0);

   for(int i=0;i<n;i++)
     {
      if(PositionSelectByTicket(m_partial_done[i]))
        {
         int k=ArraySize(kept);
         ArrayResize(kept,k+1);
         kept[k]=m_partial_done[i];
        }
     }

   ArrayFree(m_partial_done);
   ArrayResize(m_partial_done,ArraySize(kept));
   for(int i=0;i<ArraySize(kept);i++)
      m_partial_done[i]=kept[i];
  }

//+------------------------------------------------------------------+
//| Whether another clip may be added in this direction. Adds are    |
//| only allowed once price has travelled a configured distance in   |
//| our favour, which is what turns the EA into a trend follower     |
//| rather than an averaging-down machine.                           |
//+------------------------------------------------------------------+
bool CTradeExecutor::CanStack(const int dir,const double atr,string &reason,string &tag) const
  {
   tag="";

   int    count   = (dir>0) ? m_book.count_buy      : m_book.count_sell;
   double profit  = (dir>0) ? m_book.profit_buy     : m_book.profit_sell;
   double anchor  = (dir>0) ? m_book.best_buy_entry : m_book.best_sell_entry;
   int    opposite= (dir>0) ? m_book.count_sell     : m_book.count_buy;

   if(opposite>0 && !m_hedging)
     {
      reason="opposite exposure open on a netting account";
      tag="opposite exposure (netting)";
      return(false);
     }
   if(count==0)
     {
      reason="";
      return(true);                       // first clip: nothing to stack onto
     }
   if(count>=m_cfg.max_positions)
     {
      reason=StringFormat("already holding %d/%d clips",count,m_cfg.max_positions);
      tag="InpMaxPositions reached";
      return(false);
     }
   if(m_cfg.add_only_in_profit && profit<=0.0)
     {
      reason="open clips are not in profit";
      tag="open clips not in profit";
      return(false);
     }
   if(m_cfg.add_step_atr>0.0 && atr>0.0 && anchor>0.0)
     {
      double price=(dir>0) ? m_sym.Ask() : m_sym.Bid();
      double moved=(dir>0) ? price-anchor : anchor-price;
      double need =m_cfg.add_step_atr*atr;
      if(moved<need)
        {
         reason=StringFormat("price has moved %.1f%% of the %.2f ATR add-step",
                             need>0.0 ? moved/need*100.0 : 0.0,m_cfg.add_step_atr);
         tag="add-step not reached";
         return(false);
        }
     }

   reason="";
   return(true);
  }

//+------------------------------------------------------------------+
bool CTradeExecutor::TryEnter(const SSignal &sig,string &reason,string &tag)
  {
   tag="";

   int dir=sig.direction;
   if(dir==0)
     {
      reason="no direction";
      tag="no direction";
      return(false);
     }
   if(sig.atr<=0.0)
     {
      reason="atr unavailable";
      tag="ATR unavailable";
      return(false);
     }

   if(!CanStack(dir,sig.atr,reason,tag))
      return(false);

   //--- flatten the other side before turning around
   int opposite=(dir>0) ? m_book.count_sell : m_book.count_buy;
   if(opposite>0)
     {
      if(m_cfg.exit_on_flip)
         CloseDirection(-dir,"reversing into "+TsDirName(dir));
      else
        {
         reason="opposite clips still open";
         tag="opposite clips still open";
         return(false);
        }
     }

   double price = (dir>0) ? m_sym.Ask() : m_sym.Bid();
   double sl    = (dir>0) ? price-m_cfg.sl_atr*sig.atr : price+m_cfg.sl_atr*sig.atr;
   double tp    = 0.0;
   if(m_cfg.use_tp)
      tp=(dir>0) ? price+m_cfg.tp_atr*sig.atr : price-m_cfg.tp_atr*sig.atr;

   sl=ClampStop(dir,price,sl);
   tp=ClampTarget(dir,price,tp);

   double existing=m_book.Volume();
   double lots=m_risk.CalcLots(dir,price,sl,existing,reason,tag);
   if(lots<=0.0)
      return(false);

   if(!SendMarket(dir,lots,sl,tp,sig.reason))
     {
      reason="order rejected";
      tag="order rejected by the server";
      return(false);
     }

   RefreshBook();
   reason="";
   tag="entered";
   return(true);
  }

//+------------------------------------------------------------------+
//| Runs the exit ladder for one position. Order matters: hard exits |
//| first, then profit taking, then stop maintenance.                |
//+------------------------------------------------------------------+
bool CTradeExecutor::ManageOne(const ulong ticket,const SSignal &sig,const bool force_close,
                               const string force_reason)
  {
   if(!PositionSelectByTicket(ticket))
      return(false);

   long     type    = PositionGetInteger(POSITION_TYPE);
   int      dir     = (type==POSITION_TYPE_BUY) ? 1 : -1;
   double   entry   = PositionGetDouble(POSITION_PRICE_OPEN);
   double   volume  = PositionGetDouble(POSITION_VOLUME);
   double   sl      = PositionGetDouble(POSITION_SL);
   double   tp      = PositionGetDouble(POSITION_TP);
   datetime opened  = (datetime)PositionGetInteger(POSITION_TIME);
   double   price   = (dir>0) ? m_sym.Bid() : m_sym.Ask();
   double   travel  = (dir>0) ? price-entry : entry-price;
   double   atr     = sig.atr;

   //--- 1. forced flatten (session end, breaker, shutdown)
   if(force_close)
     {
      if(m_trade.PositionClose(ticket))
        {
         Log.Info(StringFormat("Closed %I64u: %s",ticket,force_reason));
         m_risk.OnPositionClosed();
         return(true);
        }
      return(false);
     }

   //--- 2. trend flipped against the position
   if(m_cfg.exit_on_flip && sig.ready && sig.trend!=0 && sig.trend!=dir)
     {
      if(m_trade.PositionClose(ticket))
        {
         Log.Info(StringFormat("Closed %I64u: trend flipped to %s",ticket,TsDirName(sig.trend)));
         m_risk.OnPositionClosed();
         return(true);
        }
     }

   //--- 3. held too long without resolving
   if(m_cfg.max_hold_seconds>0 && (int)(TimeCurrent()-opened)>=m_cfg.max_hold_seconds)
     {
      if(m_trade.PositionClose(ticket))
        {
         Log.Info(StringFormat("Closed %I64u: max holding time reached",ticket));
         m_risk.OnPositionClosed();
         return(true);
        }
     }

   if(atr<=0.0)
      return(false);

   //--- 4. safety net: a clip must never sit unprotected, e.g. if the
   //---    server rejected the stop that came with the entry
   if(sl<=0.0)
     {
      double rescue=(dir>0) ? entry-m_cfg.sl_atr*atr : entry+m_cfg.sl_atr*atr;
      rescue=ClampStop(dir,price,rescue);
      if(ModifyStops(ticket,rescue,tp))
        {
         Log.Warn(StringFormat("Ticket %I64u had no stop - attached one at %s",
                               ticket,m_sym.PriceToString(rescue)));
         sl=rescue;
        }
     }

   //--- 5. bank part of the clip once it has paid for itself
   if(m_cfg.partial_close_pct>0.0 && m_hedging && !PartialTaken(ticket) &&
      travel>=m_cfg.partial_trigger_atr*atr)
     {
      double slice=m_sym.FloorLots(volume*m_cfg.partial_close_pct/100.0);
      double rest =m_sym.FloorLots(volume-slice);
      if(slice>=m_sym.vol_min-1e-8 && rest>=m_sym.vol_min-1e-8)
        {
         if(m_trade.PositionClosePartial(ticket,slice))
           {
            Log.Info(StringFormat("Banked %s of %I64u at %.2f ATR",
                                  m_sym.LotsToString(slice),ticket,travel/atr));
            MarkPartial(ticket);
            m_risk.OnPositionClosed();
            if(!PositionSelectByTicket(ticket))
               return(true);
            volume=PositionGetDouble(POSITION_VOLUME);
           }
        }
      else
         MarkPartial(ticket);             // too small to split, do not retry every tick
     }

   //--- 6. stop maintenance: break-even first, then trailing
   double new_sl=sl;

   if(m_cfg.be_trigger_atr>0.0 && travel>=m_cfg.be_trigger_atr*atr)
     {
      double offset=m_cfg.be_offset_points*m_sym.point;
      double be=(dir>0) ? entry+offset : entry-offset;
      if(dir>0 ? (be>new_sl) : (be<new_sl || new_sl==0.0))
         new_sl=be;
     }

   if(m_cfg.trail_mode!=TS_TRAIL_NONE && travel>=m_cfg.trail_start_atr*atr)
     {
      double candidate=0.0;

      if(m_cfg.trail_mode==TS_TRAIL_ATR)
         candidate=(dir>0) ? price-m_cfg.trail_atr*atr : price+m_cfg.trail_atr*atr;
      else
         if(sig.ema_fast>0.0)
            candidate=(dir>0) ? sig.ema_fast-m_cfg.trail_atr*atr : sig.ema_fast+m_cfg.trail_atr*atr;

      if(candidate>0.0)
        {
         if(dir>0 ? (candidate>new_sl) : (candidate<new_sl || new_sl==0.0))
            new_sl=candidate;
        }
     }

   if(new_sl!=sl && new_sl>0.0)
     {
      new_sl=ClampStop(dir,price,new_sl);
      //--- never move a stop backwards, and ignore sub-point jitter
      bool improves=(dir>0) ? (new_sl>sl+m_sym.point*0.5) : (sl==0.0 || new_sl<sl-m_sym.point*0.5);
      //--- a break-even stop must not be pushed through the market
      bool valid=(dir>0) ? (new_sl<price) : (new_sl>price);
      if(improves && valid)
         return(ModifyStops(ticket,new_sl,tp));
     }

   return(false);
  }

//+------------------------------------------------------------------+
void CTradeExecutor::ManageOpen(const SSignal &sig,const bool flatten_all,const string flatten_reason)
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0)
         continue;
      if(PositionGetString(POSITION_SYMBOL)!=m_sym.symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC)!=m_cfg.magic)
         continue;

      ManageOne(ticket,sig,flatten_all,flatten_reason);
     }
  }

//+------------------------------------------------------------------+
int CTradeExecutor::CloseDirection(const int dir,const string why)
  {
   int closed=0;

   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0)
         continue;
      if(PositionGetString(POSITION_SYMBOL)!=m_sym.symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC)!=m_cfg.magic)
         continue;

      long type=PositionGetInteger(POSITION_TYPE);
      int  pos_dir=(type==POSITION_TYPE_BUY) ? 1 : -1;
      if(dir!=0 && pos_dir!=dir)
         continue;

      if(m_trade.PositionClose(ticket))
        {
         closed++;
         Log.Info(StringFormat("Closed %I64u: %s",ticket,why));
        }
      else
         Log.Warn(StringFormat("Close of %I64u failed: %u %s",
                               ticket,m_trade.ResultRetcode(),m_trade.ResultRetcodeDescription()));
     }

   if(closed>0)
     {
      m_risk.OnPositionClosed();
      RefreshBook();
     }
   return(closed);
  }

//+------------------------------------------------------------------+
int CTradeExecutor::CloseAll(const string why)
  {
   return(CloseDirection(0,why));
  }

#endif // TS_TRADEEXECUTOR_MQH
