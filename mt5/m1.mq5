//+------------------------------------------------------------------+
//|                                              PureM1Scalper.mq5   |
//|                         Master MQL5 Gold Specialist - Raw Tester |
//|                                       Platform: MetaTrader 5     |
//+------------------------------------------------------------------+
#property copyright "Master MQL5 Gold Specialist"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//+------------------------------------------------------------------+
//| PARAMETER INPUT                                                  |
//+------------------------------------------------------------------+
input ulong  InpMagicNumber = 999111; // Magic Number
input double InpLotSize     = 0.01;   // Ukuran Lot Setiap Menit

datetime last_m1_bar_time = 0;

//+------------------------------------------------------------------+
//| Auto-Detect Filling Mode Broker (Anti Gagal Eksekusi)            |
//+------------------------------------------------------------------+
void SetBrokerFillingMode()
{
   uint filling = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) != 0)
      trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((filling & SYMBOL_FILLING_IOC) != 0)
      trade.SetTypeFilling(ORDER_FILLING_IOC);
   else
      trade.SetTypeFilling(ORDER_FILLING_RETURN);
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(50); // Toleransi slippage gold
   SetBrokerFillingMode();

   // Dibiarkan 0 agar langsung mengeksekusi order pertama pada tick pertama!
   last_m1_bar_time = 0; 

   Print(">>> [PureM1] EA Dimulai pada ", _Symbol, ". Siap eksekusi 0.01 setiap menit!");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print(">>> [PureM1] EA Dihentikan.");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1. Cek apakah ada candle M1 baru (atau tick pertama saat EA baru dipasang)
   datetime current_m1_time = iTime(_Symbol, PERIOD_M1, 0);
   if(current_m1_time == 0) return; // Data chart belum siap

   if(current_m1_time == last_m1_bar_time)
   {
      return; // Belum berganti menit, lewati
   }

   // 2. Baca candle 1 (candle M1 yang baru saja tertutup sempurna)
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_M1, 1, 1, rates) < 1)
   {
      Print("[PureM1] Menunggu riwayat harga candle M1...");
      return;
   }

   // Kunci penanda waktu agar hanya eksekusi 1 kali per menit
   last_m1_bar_time = current_m1_time;

   double open_price  = rates[0].open;
   double close_price = rates[0].close;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   Print("----------------------------------------------------------");
   Print("[PureM1] MENIT BARU: ", TimeToString(current_m1_time, TIME_MINUTES|TIME_SECONDS),
         " | Candle Tutup: Open=", open_price, " Close=", close_price);

   // ================= LOGIKA MURNI =================

   // JIKA CLOSE >= OPEN (BULLISH) -> BUY 0.01 (TANPA SL / TANPA TP)
   if(close_price >= open_price)
   {
      Print("[PureM1] Sinyal: HIJAU -> Eksekusi BUY 0.01...");
      if(trade.Buy(InpLotSize, _Symbol, ask, 0, 0, "PureM1_Buy"))
      {
         Print("[PureM1] >>> SUKSES BUY 0.01 di harga: ", ask);
      }
      else
      {
         Print("[PureM1] !!! GAGAL BUY. Error: ", trade.ResultRetcode(), " (", trade.ResultRetcodeDescription(), ")");
      }
   }
   // JIKA CLOSE < OPEN (BEARISH) -> SELL 0.01 (TANPA SL / TANPA TP)
   else
   {
      Print("[PureM1] Sinyal: MERAH -> Eksekusi SELL 0.01...");
      if(trade.Sell(InpLotSize, _Symbol, bid, 0, 0, "PureM1_Sell"))
      {
         Print("[PureM1] >>> SUKSES SELL 0.01 di harga: ", bid);
      }
      else
      {
         Print("[PureM1] !!! GAGAL SELL. Error: ", trade.ResultRetcode(), " (", trade.ResultRetcodeDescription(), ")");
      }
   }
}
