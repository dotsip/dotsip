//+------------------------------------------------------------------+
//|                                              PureM1Scalper.mq5   |
//|                         Master MQL5 Gold Specialist - Audio Edit |
//|                                       Platform: MetaTrader 5     |
//+------------------------------------------------------------------+
#property copyright "Master MQL5 Gold Specialist"
#property link      "https://www.mql5.com"
#property version   "1.10"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//+------------------------------------------------------------------+
//| PARAMETER INPUT                                                  |
//+------------------------------------------------------------------+
input group "=== PENGATURAN DASAR ==="
input ulong  InpMagicNumber       = 999111;       // Magic Number
input double InpLotSize           = 0.01;         // Ukuran Lot Setiap Menit

input group "=== NOTIFIKASI SUARA (AUDIO) ==="
input bool   InpEnableSound       = true;         // Aktifkan Bunyi Saat Order?
input string InpSoundBuy          = "ok.wav";     // File Suara Order BUY
input string InpSoundSell         = "expert.wav"; // File Suara Order SELL

datetime last_m1_bar_time = 0;

//+------------------------------------------------------------------+
//| Auto-Detect Filling Mode Broker                                  |
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
   trade.SetDeviationInPoints(50);
   SetBrokerFillingMode();

   last_m1_bar_time = 0; 

   Print(">>> [PureM1] EA Dimulai. Fitur Suara: ", (InpEnableSound ? "AKTIF" : "NONAKTIF"));
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
   // 1. Cek pergantian candle M1
   datetime current_m1_time = iTime(_Symbol, PERIOD_M1, 0);
   if(current_m1_time == 0) return;

   if(current_m1_time == last_m1_bar_time)
   {
      return; // Belum berganti menit
   }

   // 2. Baca candle 1 (candle yang baru saja selesai ditutup)
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_M1, 1, 1, rates) < 1) return;

   last_m1_bar_time = current_m1_time;

   double open_price  = rates[0].open;
   double close_price = rates[0].close;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   Print("----------------------------------------------------------");
   Print("[PureM1] MENIT BARU: ", TimeToString(current_m1_time, TIME_MINUTES|TIME_SECONDS),
         " | Open=", open_price, " Close=", close_price);

   // ================= LOGIKA ORDER & SUARA =================

   // CANDLE HIJAU -> BUY
   if(close_price >= open_price)
   {
      if(trade.Buy(InpLotSize, _Symbol, ask, 0, 0, "PureM1_Buy"))
      {
         Print("[PureM1] >>> SUKSES BUY 0.01 di harga: ", ask);
         
         // Bunyikan Audio BUY
         if(InpEnableSound) PlaySound(InpSoundBuy);
      }
      else
      {
         Print("[PureM1] !!! GAGAL BUY: ", trade.ResultRetcodeDescription());
      }
   }
   // CANDLE MERAH -> SELL
   else
   {
      if(trade.Sell(InpLotSize, _Symbol, bid, 0, 0, "PureM1_Sell"))
      {
         Print("[PureM1] >>> SUKSES SELL 0.01 di harga: ", bid);
         
         // Bunyikan Audio SELL
         if(InpEnableSound) PlaySound(InpSoundSell);
      }
      else
      {
         Print("[PureM1] !!! GAGAL SELL: ", trade.ResultRetcodeDescription());
      }
   }
}
