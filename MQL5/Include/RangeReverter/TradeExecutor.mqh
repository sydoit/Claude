//+------------------------------------------------------------------+
//|                                                TradeExecutor.mqh |
//|   Order placement and the life-cycle of every open fade:         |
//|   the mean as a moving target, break-even, partial profit,       |
//|   trailing, the regime-break exit and the time exit.             |
//|                                                                  |
//|   The target is what makes this different from a trend EA. A     |
//|   fade is a bet on one specific journey - back to the middle     |
//|   band - so progress is measured as a percentage of that trip,   |
//|   not in ATR, and the target follows the mean as it moves. It    |
//|   only ever follows it CLOSER: a mean drifting away from the     |
//|   position is the range failing, not an invitation to hold on.   |
//+------------------------------------------------------------------+
#ifndef RR_TRADEEXECUTOR_MQH
#define RR_TRADEEXECUTOR_MQH

#include <Trade\Trade.mqh>
#include <RangeReverter/Config.mqh>
#include <RangeReverter/Utils.mqh>
#include <RangeReverter/SignalEngine.mqh>
#include <RangeReverter/RiskManager.mqh>

//+------------------------------------------------------------------+
//| Aggregated view of what this EA currently holds on the symbol.   |
//+------------------------------------------------------------------+
struct SRrBook
  {
   int               count_buy;
   int               count_sell;
   double            volume_buy;
   double            volume_sell;
   double            profit_buy;
   double            profit_sell;
   double            low_buy_entry;     // lowest long entry - the anchor for a further fade
   double            high_sell_entry;   // highest short entry
   datetime          newest_entry;

   int               Count(void)  const { return(count_buy+count_sell);   }
   double            Volume(void) const { return(volume_buy+volume_sell); }
   double            Profit(void) const { return(profit_buy+profit_sell); }
  };

//+------------------------------------------------------------------+
class CRrTradeExecutor
  {
private:
   SRrSettings       m_cfg;
   CRrSymbolCtx     *m_sym;
   CRrRiskManager   *m_risk;
   CTrade            m_trade;
   SRrBook           m_book;
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
   double            MeanTarget(const int dir,const double price,const double mid) const;
   bool              RegimeBroke(const int dir,const SRrSignal &sig,string &why) const;
   bool              ManageOne(const ulong ticket,const SRrSignal &sig,const bool force_close,
                               const string force_reason);

public:
                     CRrTradeExecutor(void): m_sym(NULL),m_risk(NULL),m_hedging(true) {}

   bool              Init(const SRrSettings &cfg,CRrSymbolCtx *sym,CRrRiskManager *risk);

   void              RefreshBook(void);
   SRrBook           Book(void) const { return(m_book); }
   bool              IsHedging(void) const { return(m_hedging); }

   bool              CanOpen(const int dir,const double atr,string &reason,string &tag) const;
   bool              TryEnter(const SRrSignal &sig,string &reason,string &tag);
   void              ManageOpen(const SRrSignal &sig,const bool flatten_all,const string flatten_reason);
   int               CloseDirection(const int dir,const string why);
   int               CloseAll(const string why);
  };

//+------------------------------------------------------------------+
bool CRrTradeExecutor::Init(const SRrSettings &cfg,CRrSymbolCtx *sym,CRrRiskManager *risk)
  {
   m_cfg  = cfg;
   m_sym  = sym;
   m_risk = risk;

   m_hedging=(ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING;

   m_trade.SetExpertMagicNumber((ulong)m_cfg.magic);
   m_trade.SetDeviationInPoints((ulong)MathMax(1,m_cfg.max_slippage_points));
   m_trade.SetTypeFillingBySymbol(m_sym.symbol);
   m_trade.SetAsyncMode(false);
   m_trade.LogLevel((ENUM_LOG_LEVELS)(RLog.Level()>=RR_LOG_DEBUG ? LOG_LEVEL_ALL : LOG_LEVEL_ERRORS));

   ArrayResize(m_partial_done,0);

   if(!m_hedging)
      RLog.Warn("Netting account detected - stacked clips merge into one position, "
                "so per-clip targets and partial closes apply to the merged position");

   RLog.Info(StringFormat("Execution: magic %I64d, slippage %dpt, %s account",
                          m_cfg.magic,m_cfg.max_slippage_points,m_hedging ? "hedging" : "netting"));
   return(true);
  }

//+------------------------------------------------------------------+
void CRrTradeExecutor::RefreshBook(void)
  {
   m_book.count_buy       = 0;
   m_book.count_sell      = 0;
   m_book.volume_buy      = 0.0;
   m_book.volume_sell     = 0.0;
   m_book.profit_buy      = 0.0;
   m_book.profit_sell     = 0.0;
   m_book.low_buy_entry   = 0.0;
   m_book.high_sell_entry = 0.0;
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
         //--- the anchor for a further fade is the WORST fill, not the best
         if(m_book.low_buy_entry==0.0 || price<m_book.low_buy_entry)
            m_book.low_buy_entry=price;
        }
      else
        {
         m_book.count_sell++;
         m_book.volume_sell+=volume;
         m_book.profit_sell+=profit;
         if(m_book.high_sell_entry==0.0 || price>m_book.high_sell_entry)
            m_book.high_sell_entry=price;
        }
     }

   PrunePartials();
  }

//+------------------------------------------------------------------+
bool CRrTradeExecutor::IsRetryable(const uint code) const
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
//| close is rejected outright by the server, which would leave the  |
//| position unprotected, so we widen instead of failing.            |
//+------------------------------------------------------------------+
double CRrTradeExecutor::ClampStop(const int dir,const double price,const double raw_sl) const
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
double CRrTradeExecutor::ClampTarget(const int dir,const double price,const double raw_tp) const
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
//| Where the target sits for a fade opened at 'price'. In mean mode |
//| it is a fraction of the way to the middle band; in ATR mode it   |
//| is a plain multiple. Returns 0 when the mean is on the wrong     |
//| side of the entry, which is the caller's cue to stand aside.     |
//+------------------------------------------------------------------+
double CRrTradeExecutor::MeanTarget(const int dir,const double price,const double mid) const
  {
   if(m_cfg.target_mode==RR_TARGET_ATR)
      return(0.0);          // caller uses the ATR form instead

   double travel=(dir>0) ? (mid-price) : (price-mid);
   if(travel<=0.0)
      return(0.0);

   double want=travel*m_cfg.target_mid_fraction;
   return((dir>0) ? price+want : price-want);
  }

//+------------------------------------------------------------------+
//| Has the range failed under an open fade? Two ways it can: the    |
//| trend measure wakes up, or price simply keeps going past the     |
//| band we faded. Either one means the premise is gone.             |
//+------------------------------------------------------------------+
bool CRrTradeExecutor::RegimeBroke(const int dir,const SRrSignal &sig,string &why) const
  {
   if(!m_cfg.exit_on_regime_break || !sig.ready)
      return(false);

   if(m_cfg.adx_exit>0.0 && sig.adx>=m_cfg.adx_exit)
     {
      why=StringFormat("ADX %.1f - the range is breaking",sig.adx);
      return(true);
     }

   if(m_cfg.break_exit_atr>0.0 && sig.atr>0.0)
     {
      double slack=m_cfg.break_exit_atr*sig.atr;
      if(dir>0 && sig.lower>0.0 && m_sym.Bid()<sig.lower-slack)
        {
         why=StringFormat("price %.2f ATR below the lower band",
                          (sig.lower-m_sym.Bid())/sig.atr);
         return(true);
        }
      if(dir<0 && sig.upper>0.0 && m_sym.Ask()>sig.upper+slack)
        {
         why=StringFormat("price %.2f ATR above the upper band",
                          (m_sym.Ask()-sig.upper)/sig.atr);
         return(true);
        }
     }

   return(false);
  }

//+------------------------------------------------------------------+
//| Market order with bounded retries. Prices are re-read on every   |
//| attempt so a requote does not resend a stale level.              |
//+------------------------------------------------------------------+
bool CRrTradeExecutor::SendMarket(const int dir,const double lots,const double sl,const double tp,
                                  const string why)
  {
   int attempts=MathMax(1,m_cfg.order_retries);

   for(int attempt=1;attempt<=attempts;attempt++)
     {
      m_sym.RefreshLevels();

      double price = (dir>0) ? m_sym.Ask() : m_sym.Bid();
      if(price<=0.0)
        {
         RLog.Warn("No price available - skipping this attempt");
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
         RLog.Info(StringFormat("%s %s @ %s SL %s TP %s (%s)",
                                RrDirName(dir),m_sym.LotsToString(m_trade.ResultVolume()),
                                m_sym.PriceToString(m_trade.ResultPrice()),
                                m_sym.PriceToString(use_sl),
                                use_tp>0.0 ? m_sym.PriceToString(use_tp) : "-",
                                why));
         return(true);
        }

      RLog.Warn(StringFormat("Order attempt %d/%d failed: %u %s",
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
bool CRrTradeExecutor::ModifyStops(const ulong ticket,const double sl,const double tp)
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
         RLog.Debug(StringFormat("Ticket %I64u is inside the freeze level - update deferred",ticket));
         return(false);
        }
     }

   if(m_trade.PositionModify(ticket,sl,tp))
      return(true);

   uint code=m_trade.ResultRetcode();
   if(code!=TRADE_RETCODE_NO_CHANGES)
      RLog.Warn(StringFormat("Stop/target update on %I64u failed: %u %s",
                             ticket,code,m_trade.ResultRetcodeDescription()));
   return(false);
  }

//+------------------------------------------------------------------+
bool CRrTradeExecutor::PartialTaken(const ulong ticket) const
  {
   int n=ArraySize(m_partial_done);
   for(int i=0;i<n;i++)
      if(m_partial_done[i]==ticket)
         return(true);
   return(false);
  }

//+------------------------------------------------------------------+
void CRrTradeExecutor::MarkPartial(const ulong ticket)
  {
   int n=ArraySize(m_partial_done);
   ArrayResize(m_partial_done,n+1);
   m_partial_done[n]=ticket;
  }

//+------------------------------------------------------------------+
//| Drops tickets that are no longer open so the list cannot grow    |
//| without bound over a long run.                                   |
//+------------------------------------------------------------------+
void CRrTradeExecutor::PrunePartials(void)
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
//| Whether a fade may be opened in this direction.                  |
//|                                                                  |
//| With the default InpMaxPositions = 1 this is simply "nothing is  |
//| already open". Anything above 1 means adding while the first     |
//| clip is losing, which is averaging down; it is allowed, but only |
//| after price has extended a full add-step further beyond the      |
//| worst existing fill, and the total volume cap still applies.     |
//+------------------------------------------------------------------+
bool CRrTradeExecutor::CanOpen(const int dir,const double atr,string &reason,string &tag) const
  {
   tag="";

   int    count    = (dir>0) ? m_book.count_buy     : m_book.count_sell;
   int    opposite = (dir>0) ? m_book.count_sell    : m_book.count_buy;
   double anchor   = (dir>0) ? m_book.low_buy_entry : m_book.high_sell_entry;

   if(opposite>0 && !m_hedging)
     {
      reason="opposite exposure open on a netting account";
      tag="opposite exposure (netting)";
      return(false);
     }
   if(count==0)
     {
      reason="";
      return(true);
     }
   if(count>=m_cfg.max_positions)
     {
      reason=StringFormat("already holding %d/%d clips",count,m_cfg.max_positions);
      tag="InpMaxPositions reached";
      return(false);
     }
   if(m_cfg.add_step_atr>0.0 && atr>0.0 && anchor>0.0)
     {
      double price=(dir>0) ? m_sym.Ask() : m_sym.Bid();
      double moved=(dir>0) ? anchor-price : price-anchor;   // further INTO the extreme
      double need =m_cfg.add_step_atr*atr;
      if(moved<need)
        {
         reason=StringFormat("price has extended %.1f%% of the %.2f ATR add-step",
                             need>0.0 ? moved/need*100.0 : 0.0,m_cfg.add_step_atr);
         tag="add-step not reached";
         return(false);
        }
     }

   reason="";
   return(true);
  }

//+------------------------------------------------------------------+
bool CRrTradeExecutor::TryEnter(const SRrSignal &sig,string &reason,string &tag)
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

   if(!CanOpen(dir,sig.atr,reason,tag))
      return(false);

   //--- a fade in the other direction means the far band has been reached,
   //--- which is where the existing clip wanted to go anyway
   int opposite=(dir>0) ? m_book.count_sell : m_book.count_buy;
   if(opposite>0)
     {
      CloseDirection(-dir,"the other band was reached");
      RefreshBook();
     }

   double price=(dir>0) ? m_sym.Ask() : m_sym.Bid();

   //--- target first: if the mean is not far enough away there is no trade
   double tp=0.0;
   if(m_cfg.target_mode==RR_TARGET_MEAN)
     {
      tp=MeanTarget(dir,price,sig.mid);
      if(tp<=0.0)
        {
         reason="the mean is already on the wrong side of the entry";
         tag="target too close to the entry";
         return(false);
        }
     }
   else
      tp=(dir>0) ? price+m_cfg.tp_atr*sig.atr : price-m_cfg.tp_atr*sig.atr;

   //--- stop: the ATR distance, or outside the faded band, whichever is further
   double sl=(dir>0) ? price-m_cfg.sl_atr*sig.atr : price+m_cfg.sl_atr*sig.atr;
   if(m_cfg.sl_beyond_band_atr>0.0)
     {
      double band=(dir>0) ? sig.lower-m_cfg.sl_beyond_band_atr*sig.atr
                          : sig.upper+m_cfg.sl_beyond_band_atr*sig.atr;
      sl=(dir>0) ? MathMin(sl,band) : MathMax(sl,band);
     }

   sl=ClampStop(dir,price,sl);
   tp=ClampTarget(dir,price,tp);

   double risk  =(dir>0) ? price-sl : sl-price;
   double reward=(dir>0) ? tp-price : price-tp;

   if(risk<=0.0 || reward<=0.0)
     {
      reason="stop or target landed on the wrong side of the entry";
      tag="target too close to the entry";
      return(false);
     }
   if(m_cfg.min_reward_risk>0.0 && reward<m_cfg.min_reward_risk*risk)
     {
      reason=StringFormat("reward/risk %.2f below the %.2f floor",reward/risk,m_cfg.min_reward_risk);
      tag="reward/risk below the floor";
      return(false);
     }

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
//| Runs the exit ladder for one position. Order matters: the exits  |
//| that mean "the premise is gone" come first, then profit taking,  |
//| then stop and target maintenance.                                |
//+------------------------------------------------------------------+
bool CRrTradeExecutor::ManageOne(const ulong ticket,const SRrSignal &sig,const bool force_close,
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
         RLog.Info(StringFormat("Closed %I64u: %s",ticket,force_reason));
         m_risk.OnPositionClosed();
         return(true);
        }
      return(false);
     }

   //--- 2. the range broke. This is the exit that keeps a mean reverter
   //---    alive: without it the EA holds its fade into the trend that
   //---    was busy invalidating it.
   string broke="";
   if(RegimeBroke(dir,sig,broke))
     {
      if(m_trade.PositionClose(ticket))
        {
         RLog.Info(StringFormat("Closed %I64u: %s",ticket,broke));
         m_risk.OnPositionClosed();
         return(true);
        }
     }

   //--- 3. held too long without reverting
   if(m_cfg.max_hold_seconds>0 && (int)(TimeCurrent()-opened)>=m_cfg.max_hold_seconds)
     {
      if(m_trade.PositionClose(ticket))
        {
         RLog.Info(StringFormat("Closed %I64u: max holding time reached",ticket));
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
         RLog.Warn(StringFormat("Ticket %I64u had no stop - attached one at %s",
                                ticket,m_sym.PriceToString(rescue)));
         sl=rescue;
        }
     }

   //--- 5. and the same for the target. Every rule below measures progress
   //---    as a percentage of the way to it, so a position with no target
   //---    would silently never reach break-even, trail or bank a partial.
   if(tp<=0.0)
     {
      double rescue_tp=(m_cfg.target_mode==RR_TARGET_MEAN && sig.ready && sig.mid>0.0)
                       ? MeanTarget(dir,entry,sig.mid)
                       : ((dir>0) ? entry+m_cfg.tp_atr*atr : entry-m_cfg.tp_atr*atr);
      if(rescue_tp>0.0)
        {
         rescue_tp=ClampTarget(dir,price,rescue_tp);
         if(ModifyStops(ticket,sl,rescue_tp))
           {
            RLog.Warn(StringFormat("Ticket %I64u had no target - attached one at %s",
                                   ticket,m_sym.PriceToString(rescue_tp)));
            tp=rescue_tp;
           }
        }
     }

   //--- 6. the moving mean. The target follows it, but only inwards: a
   //---    mean running away from the position is the range failing.
   double new_tp=tp;

   if(m_cfg.track_mean && m_cfg.target_mode==RR_TARGET_MEAN && sig.ready && sig.mid>0.0)
     {
      double want=MeanTarget(dir,entry,sig.mid);
      if(want>0.0)
        {
         double candidate=m_sym.NormalizePrice(want);

         //--- closer to the entry than the target we already hold?
         bool closer =(dir>0) ? (candidate<new_tp || new_tp<=0.0)
                              : (candidate>new_tp || new_tp<=0.0);
         bool reached=(dir>0) ? (price>=candidate) : (price<=candidate);

         //--- the mean has come to us: take it at market, because a target
         //--- behind the market is one the server would refuse anyway
         if(closer && reached && travel>0.0)
           {
            if(m_trade.PositionClose(ticket))
              {
               RLog.Info(StringFormat("Closed %I64u: the mean came to the position",ticket));
               m_risk.OnPositionClosed();
               return(true);
              }
           }

         //--- otherwise tighten, but only to a level the server will accept
         if(closer && !reached)
           {
            double min_dist=m_sym.MinStopDistance();
            bool   room=(dir>0) ? (candidate-price>=min_dist) : (price-candidate>=min_dist);
            if(room)
               new_tp=candidate;
           }
        }
     }

   //--- progress along the one journey this trade is betting on
   double goal=(new_tp>0.0) ? ((dir>0) ? new_tp-entry : entry-new_tp) : 0.0;
   double progress=(goal>0.0) ? travel/goal*100.0 : 0.0;

   //--- 7. bank part of the clip once it is most of the way home
   if(m_cfg.partial_close_pct>0.0 && m_hedging && !PartialTaken(ticket) &&
      goal>0.0 && progress>=m_cfg.partial_trigger_pct)
     {
      double slice=m_sym.FloorLots(volume*m_cfg.partial_close_pct/100.0);
      double rest =m_sym.FloorLots(volume-slice);
      if(slice>=m_sym.vol_min-1e-8 && rest>=m_sym.vol_min-1e-8)
        {
         if(m_trade.PositionClosePartial(ticket,slice))
           {
            RLog.Info(StringFormat("Banked %s of %I64u at %.0f%% of the way to the mean",
                                   m_sym.LotsToString(slice),ticket,progress));
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

   //--- 8. stop maintenance: break-even first, then trailing
   double new_sl=sl;

   if(m_cfg.be_trigger_pct>0.0 && goal>0.0 && progress>=m_cfg.be_trigger_pct)
     {
      double offset=m_cfg.be_offset_points*m_sym.point;
      double be=(dir>0) ? entry+offset : entry-offset;
      if(dir>0 ? (be>new_sl) : (be<new_sl || new_sl==0.0))
         new_sl=be;
     }

   if(m_cfg.trail_mode==RR_TRAIL_ATR && goal>0.0 && progress>=m_cfg.trail_start_pct)
     {
      double candidate=(dir>0) ? price-m_cfg.trail_atr*atr : price+m_cfg.trail_atr*atr;
      if(dir>0 ? (candidate>new_sl) : (candidate<new_sl || new_sl==0.0))
         new_sl=candidate;
     }

   if(new_sl!=sl && new_sl>0.0)
     {
      new_sl=ClampStop(dir,price,new_sl);
      //--- never move a stop backwards, and ignore sub-point jitter
      bool improves=(dir>0) ? (new_sl>sl+m_sym.point*0.5) : (sl==0.0 || new_sl<sl-m_sym.point*0.5);
      //--- a break-even stop must not be pushed through the market
      bool valid=(dir>0) ? (new_sl<price) : (new_sl>price);
      if(!improves || !valid)
         new_sl=sl;
     }
   else
      new_sl=sl;

   //--- one order for whatever actually changed
   bool sl_changed=(MathAbs(new_sl-sl)>m_sym.point*0.5);
   bool tp_changed=(new_tp>0.0 && MathAbs(new_tp-tp)>m_sym.point*0.5);

   if(sl_changed || tp_changed)
      return(ModifyStops(ticket,new_sl,new_tp));

   return(false);
  }

//+------------------------------------------------------------------+
void CRrTradeExecutor::ManageOpen(const SRrSignal &sig,const bool flatten_all,const string flatten_reason)
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
int CRrTradeExecutor::CloseDirection(const int dir,const string why)
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
         RLog.Info(StringFormat("Closed %I64u: %s",ticket,why));
        }
      else
         RLog.Warn(StringFormat("Close of %I64u failed: %u %s",
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
int CRrTradeExecutor::CloseAll(const string why)
  {
   return(CloseDirection(0,why));
  }

#endif // RR_TRADEEXECUTOR_MQH
