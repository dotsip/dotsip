//+------------------------------------------------------------------+
//|         M5_Martingale_Recovery_Balance.mq5                       |
//|   Versi stabil + Reset lot berdasarkan Balance                   |
//+------------------------------------------------------------------+
#property copyright "M5 Martingale Balance Recovery"
#property version   "20.50"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

input group "=== Trading ==="
input double   InpLotAwal              = 0.01;
input double   InpMaxLot               = 0.32;
input ulong    InpMagicNumber          = 101010;
input int      InpMaxSpread            = 500;
input int      InpSlippage             = 30;

input group "=== Pemicu M5 & TP/SL ==="
input int      InpMinRangePoints       = 300;
input double   InpSL_BufferPoints      = 50;
input double   InpTP_Factor            = 1.5;
input int      InpLookbackCandles      = 5;

input group "=== Recovery ==="
input bool     InpCloseProfitOnM5      = true;     // Tutup jika floating profit di M5 close

input bool     InpEnableLogging        = true;

CTrade        trade;
CPositionInfo pos;

double   g_current_lot           = 0;
bool     g_position_open         = false;
bool     g_is_martingale         = false;
double   g_balance_before_marti  = 0;        // Balance saat mulai martingale
datetime g_last_m5_time          = 0;
ENUM_POSITION_TYPE g_last_type   = WRONG_VALUE;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   g_current_lot  = InpLotAwal;
   g_last_m5_time = iTime(_Symbol, PERIOD_M5, 0);

   Print("=== M5 Martingale Balance Recovery v20.50 ===");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason){}

void OnTick()
{
   CheckPositionStatus();
   CheckM5Close();
}

//+------------------------------------------------------------------+
void CheckPositionStatus()
{
   bool found = false;
   ENUM_POSITION_TYPE current_type = WRONG_VALUE;

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(pos.SelectByIndex(i) && pos.Symbol() == _Symbol && pos.Magic() == InpMagicNumber)
      {
         found = true;
         current_type = pos.PositionType();
         break;
      }
   }

   if(g_position_open && !found)
   {
      double profit = GetLastClosedProfit();

      if(profit < 0)
      {
         // ===== KENA SL =====
         if(!g_is_martingale)
         {
            // Pertama kali masuk martingale → catat balance
            g_balance_before_marti = AccountInfoDouble(ACCOUNT_BALANCE);
            g_is_martingale = true;

            if(InpEnableLogging)
               Print(">>> MULAI MARTINGALE | Balance dicatat: ", DoubleToString(g_balance_before_marti, 2));
         }

         g_current_lot = NormalizeLot(g_current_lot * 2.0);
         if(g_current_lot > InpMaxLot) g_current_lot = InpMaxLot;

         bool new_is_buy = (g_last_type == POSITION_TYPE_SELL);

         if(InpEnableLogging)
            Print(">>> KENA SL | Flip ke ", (new_is_buy ? "BUY" : "SELL"), " | Lot: ", g_current_lot);

         OpenFromCurrentM5(new_is_buy, true);
      }
      else
      {
         // ===== DITUTUP DENGAN PROFIT =====
         double current_balance = AccountInfoDouble(ACCOUNT_BALANCE);

         if(InpEnableLogging)
            Print(">>> CLOSE PROFIT +", DoubleToString(profit, 2),
                  " | Balance sekarang: ", DoubleToString(current_balance, 2),
                  " | Target: ", DoubleToString(g_balance_before_marti, 2));

         if(g_is_martingale)
         {
            if(current_balance >= g_balance_before_marti)
            {
               // Sudah recovery dari balance awal → Reset
               g_current_lot          = InpLotAwal;
               g_is_martingale        = false;
               g_balance_before_marti = 0;

               if(InpEnableLogging)
                  Print(">>> RECOVERY SELESAI (Balance sudah kembali) | Lot direset ke ", g_current_lot);
            }
            else
            {
               // Belum recovery → Lot tetap
               if(InpEnableLogging)
                  Print(">>> Belum recovery | Lot tetap ", g_current_lot);
            }
         }
         else
         {
            // Bukan martingale → pastikan lot normal
            g_current_lot = InpLotAwal;
         }
      }
   }

   g_position_open = found;
   if(found) g_last_type = current_type;
}

double GetLastClosedProfit()
{
   HistorySelect(TimeCurrent()-86400, TimeCurrent());
   for(int i = HistoryDealsTotal()-1; i >= 0; i--)
   {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0) continue;
      if(HistoryDealGetString(t, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(t, DEAL_MAGIC) != InpMagicNumber) continue;
      if(HistoryDealGetInteger(t, DEAL_ENTRY) == DEAL_ENTRY_OUT ||
         HistoryDealGetInteger(t, DEAL_ENTRY) == DEAL_ENTRY_OUT_BY)
      {
         return HistoryDealGetDouble(t, DEAL_PROFIT) +
                HistoryDealGetDouble(t, DEAL_SWAP) +
                HistoryDealGetDouble(t, DEAL_COMMISSION);
      }
   }
   return 0;
}

//+------------------------------------------------------------------+
void CheckM5Close()
{
   datetime current_m5 = iTime(_Symbol, PERIOD_M5, 0);
   if(current_m5 == g_last_m5_time) return;
   g_last_m5_time = current_m5;

   // Safety Close
   if(g_position_open && g_is_martingale && InpCloseProfitOnM5)
   {
      double floating = 0;
      for(int i = PositionsTotal()-1; i >= 0; i--)
      {
         if(pos.SelectByIndex(i) && pos.Symbol() == _Symbol && pos.Magic() == InpMagicNumber)
         {
            floating = pos.Profit() + pos.Swap();
            break;
         }
      }

      if(floating > 0)
      {
         if(CloseMyPosition())
         {
            if(InpEnableLogging)
               Print(">>> SAFETY CLOSE | Floating +", DoubleToString(floating, 2));
            g_position_open = false;
         }
         return;
      }
   }

   if(g_position_open) return;

   // Sinyal M5
   double high  = iHigh(_Symbol, PERIOD_M5, 1);
   double low   = iLow(_Symbol, PERIOD_M5, 1);
   double open  = iOpen(_Symbol, PERIOD_M5, 1);
   double close = iClose(_Symbol, PERIOD_M5, 1);

   double range_points = (high - low) / _Point;
   if(range_points < InpMinRangePoints) return;

   bool has_significant = false;
   for(int i = 1; i <= InpLookbackCandles; i++)
   {
      double r = (iHigh(_Symbol, PERIOD_M5, i) - iLow(_Symbol, PERIOD_M5, i)) / _Point;
      if(r >= InpMinRangePoints)
      {
         has_significant = true;
         break;
      }
   }
   if(!has_significant) return;

   bool is_buy = (close > open);

   double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
   if(spread > InpMaxSpread) return;

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED)) return;

   OpenFromCurrentM5(is_buy, g_is_martingale);
}

//+------------------------------------------------------------------+
void OpenFromCurrentM5(bool is_buy, bool is_flip)
{
   double high  = iHigh(_Symbol, PERIOD_M5, 1);
   double low   = iLow(_Symbol, PERIOD_M5, 1);
   double range_points = (high - low) / _Point;
   if(range_points < 50) range_points = 50;

   double price  = is_buy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int digits    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double buffer = InpSL_BufferPoints * _Point;

   double sl, tp;

   if(is_buy)
   {
      sl = NormalizeDouble(low - buffer, digits);
      int sl_points = (int)MathRound((price - sl) / _Point);
      if(sl_points < 80) sl = NormalizeDouble(price - 80 * _Point, digits);

      int tp_points = (int)MathRound(range_points * InpTP_Factor);
      if(tp_points < 100) tp_points = 100;
      tp = NormalizeDouble(price + tp_points * _Point, digits);
   }
   else
   {
      sl = NormalizeDouble(high + buffer, digits);
      int sl_points = (int)MathRound((sl - price) / _Point);
      if(sl_points < 80) sl = NormalizeDouble(price + 80 * _Point, digits);

      int tp_points = (int)MathRound(range_points * InpTP_Factor);
      if(tp_points < 100) tp_points = 100;
      tp = NormalizeDouble(price - tp_points * _Point, digits);
   }

   double lot = NormalizeLot(g_current_lot);
   string comment = is_flip ? "M5 RECOVERY" : "M5 Signal";

   bool ok = is_buy ?
             trade.Buy(lot, _Symbol, price, sl, tp, comment) :
             trade.Sell(lot, _Symbol, price, sl, tp, comment);

   if(ok)
   {
      g_position_open = true;
      g_last_type     = is_buy ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;

      Print("========================================");
      Print(">>> ", (is_flip ? "RECOVERY" : "ENTRY"), " ", (is_buy ? "BUY" : "SELL"), " | Lot: ", lot);
      Print("SL: ", DoubleToString(sl, digits), " | TP: ", DoubleToString(tp, digits));
      if(g_is_martingale)
         Print("Target Balance: ", DoubleToString(g_balance_before_marti, 2));
      Print("========================================");
   }
   else
   {
      Print("Gagal order: ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
bool CloseMyPosition()
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(pos.SelectByIndex(i) && pos.Symbol() == _Symbol && pos.Magic() == InpMagicNumber)
         return trade.PositionClose(pos.Ticket());
   }
   return false;
}

//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double min_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lot_step <= 0) lot_step = 0.01;
   if(lot < min_lot) lot = min_lot;
   if(lot > max_lot) lot = max_lot;
   if(lot > InpMaxLot) lot = InpMaxLot;

   lot = MathFloor(lot / lot_step + 0.0000001) * lot_step;
   return NormalizeDouble(lot, 2);
}
//+------------------------------------------------------------------+
