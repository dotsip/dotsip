//+------------------------------------------------------------------+
//|                                             ZeroLevelBot_Pro.mq5 |
//|  100% Full Auto Directional Crossing & Reverse Martingale        |
//|  Auto-Calibrated TP/SL + Max Step 6 Safety Hedge Lock            |
//|                                      https://cindo.pages.dev     |
//+------------------------------------------------------------------+
#property copyright   "Mochamad Tabrani & Antigravity AI"
#property link        "https://cindo.pages.dev"
#property version     "5.00"
#property description "Minimalist High-Speed Algorithmic Bot: Zero-Level Crossing & Reverse Martingale"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| [1] Parameter Input Sederhana                                    |
//+------------------------------------------------------------------+
input group "=== PENGATURAN STRATEGI UTAMA ==="
input bool            InpEnableBot         = true;      // 🤖 Aktifkan Robot Otomatis?
input double          InpStartLot          = 0.01;      // Lot Dasar Awal (Step 1)
input double          InpLotMultiplier     = 2.0;       // Faktor Pengali Martingale (2.0x)
input int             InpMaxSteps          = 6;         // Batas Maksimal Step Pembalikan (Default: 6)
input double          InpPriceInterval     = 1.0;       // Jarak Level Angka Bulat Pemicu ($1.00)
input double          InpTargetDistance    = 1.0;       // Jarak TP & SL Presisi dari Entry ($1.00 = 10 Pips)
input bool            InpHedgeOnMaxStep    = true;      // 🔒 Kunci Akun (Hedge 1:1) jika Step 6 Kena SL?

input group "=== PENGATURAN NOTIFIKASI & BROKER ==="
input bool            InpEnableAlert       = true;      // Popup Alert di Layar MT5?
input bool            InpEnablePush        = false;     // Notifikasi ke HP (MetaQuotes ID)?
input int             InpSlippage          = 50;        // Toleransi Slippage (pts)
input long            InpMagicBot          = 888100;    // Magic Number Khusus Bot Ini

//+------------------------------------------------------------------+
//| [2] Variabel Global Ringan                                       |
//+------------------------------------------------------------------+
double            g_point;
int               g_digits;
int               g_currentStep     = 1;
double            g_currentBotLot   = 0.01;
bool              g_isHedgeLocked   = false;
ulong             g_lastManagedDeal = 0;
double            g_lastPrice       = 0.0;
CTrade            g_trade;

//+------------------------------------------------------------------+
//| [3] Lifecycle Inisialisasi                                       |
//+------------------------------------------------------------------+
int OnInit()
{
   g_point         = _Point;
   g_digits        = _Digits;
   g_currentBotLot = InpStartLot;
   g_currentStep   = 1;
   g_isHedgeLocked = false;
   g_lastPrice     = 0.0;

   g_trade.SetExpertMagicNumber(InpMagicBot);
   g_trade.SetDeviationInPoints(InpSlippage);
   g_trade.SetTypeFilling(GetOptimalFilling(_Symbol));

   Print("=== ZeroLevelBot v5.00 Minimalis Aktif ===");
   UpdateChartComment();
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Comment("");
   Print("=== ZeroLevelBot Dihentikan ===");
}

//+------------------------------------------------------------------+
//| [4] Eksekusi Tiap Tick (Kecepatan Tinggi)                        |
//+------------------------------------------------------------------+
void OnTick()
{
   if(InpEnableBot && !g_isHedgeLocked)
   {
      CheckDirectionalCrossing();
   }

   UpdateChartComment();
}

//+------------------------------------------------------------------+
//| [5] Mesin Pemicu: Directional Crossing Level Angka Bulat         |
//+------------------------------------------------------------------+
void CheckDirectionalCrossing()
{
   if(CountBotPositions() > 0)
   {
      g_lastPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      return;
   }

   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(g_lastPrice <= 0.0)
   {
      g_lastPrice = currentBid;
      return;
   }

   double step = (InpPriceInterval > 0) ? InpPriceInterval : 1.0;

   // Crossing NAIK -> BUY
   double targetLevelUp = MathFloor(currentBid / step) * step;
   if(g_lastPrice < targetLevelUp && currentBid >= targetLevelUp)
   {
      Print(StringFormat("🚀 [CROSSING BUY] Melintas naik level %.2f!", targetLevelUp));
      OpenZeroBotOrder(POSITION_TYPE_BUY, g_currentBotLot);
      g_lastPrice = currentBid;
      return;
   }

   // Crossing TURUN -> SELL
   double targetLevelDown = MathCeil(currentBid / step) * step;
   if(g_lastPrice > targetLevelDown && currentBid <= targetLevelDown)
   {
      Print(StringFormat("🔻 [CROSSING SELL] Melintas turun level %.2f!", targetLevelDown));
      OpenZeroBotOrder(POSITION_TYPE_SELL, g_currentBotLot);
      g_lastPrice = currentBid;
      return;
   }

   g_lastPrice = currentBid;
}

//+------------------------------------------------------------------+
//| [6] Transaksi: Kalibrasi Presisi & Reverse Martingale            |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   ulong dealTicket = trans.deal;
   if(dealTicket == 0 || !HistoryDealSelect(dealTicket)) return;

   long   dealEntry = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   long   dealType  = HistoryDealGetInteger(dealTicket, DEAL_TYPE);
   string sym       = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
   long   magic     = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
   long   dealReason= HistoryDealGetInteger(dealTicket, DEAL_REASON);

   if(sym != _Symbol || magic != InpMagicBot) return;

   // 1. Kalibrasi Instan saat Order Terisi (Slippage-Immune)
   if(dealEntry == DEAL_ENTRY_IN)
   {
      ulong posTicket   = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      double exactPrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
      ENUM_POSITION_TYPE pType = (dealType == DEAL_TYPE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;

      CalibratePositionTPSL(posTicket, exactPrice, pType);
      return;
   }

   // 2. Eksekusi Lanjutan saat Order Tertutup
   if(dealEntry == DEAL_ENTRY_OUT)
   {
      if(dealTicket == g_lastManagedDeal) return;
      g_lastManagedDeal = dealTicket;

      double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
      ENUM_POSITION_TYPE origPosType = (dealType == DEAL_TYPE_SELL) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;

      // KASUS A: TAKE PROFIT TERSENTUH
      if(dealReason == DEAL_REASON_TP || profit > 0)
      {
         string msg = StringFormat("🎯 [STEP %d TP HIT!] Profit: $%.2f. Reset ke Step 1 & Lanjut Tren...", g_currentStep, profit);
         Print(msg);
         if(InpEnableAlert) Alert(msg);

         g_currentStep   = 1;
         g_currentBotLot = InpStartLot;

         if(InpEnableBot && !g_isHedgeLocked)
            OpenZeroBotOrder(origPosType, g_currentBotLot);
      }
      // KASUS B: STOP LOSS TERSENTUH
      else if(dealReason == DEAL_REASON_SL || profit < 0)
      {
         if(g_currentStep >= InpMaxSteps)
         {
            string msg = StringFormat("🚨 [MAKSIMAL STEP %d TERCAPAI!] Mengunci Akun HEDGE 1:1...", g_currentStep);
            Print(msg);
            if(InpEnableAlert) Alert(msg);
            if(InpEnablePush)  SendNotification(msg);

            g_isHedgeLocked = true;
            if(InpHedgeOnMaxStep) ExecuteEmergencyHedge();
            return;
         }

         g_currentStep++;
         g_currentBotLot = NormalizeLotSize(g_currentBotLot * InpLotMultiplier);

         string msg = StringFormat("🛑 [STEP %d SL HIT!] Balik Arah ke STEP %d (Lot: %.2f)...", g_currentStep - 1, g_currentStep, g_currentBotLot);
         Print(msg);
         if(InpEnableAlert) Alert(msg);

         if(InpEnableBot && !g_isHedgeLocked)
         {
            ENUM_POSITION_TYPE reverseType = (origPosType == POSITION_TYPE_BUY) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;
            OpenZeroBotOrder(reverseType, g_currentBotLot);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| [7] Kalibrasi Pasca-Eksekusi (Menghapus Kesalahan Selisih Pips)   |
//+------------------------------------------------------------------+
void CalibratePositionTPSL(ulong posTicket, double exactPrice, ENUM_POSITION_TYPE posType)
{
   if(!PositionSelectByTicket(posTicket)) return;

   double dist = (InpTargetDistance > 0) ? InpTargetDistance : 1.0;
   double exactTP = (posType == POSITION_TYPE_BUY) ? (exactPrice + dist) : (exactPrice - dist);
   double exactSL = (posType == POSITION_TYPE_BUY) ? (exactPrice - dist) : (exactPrice + dist);
   exactTP = NormalizeDouble(exactTP, g_digits);
   exactSL = NormalizeDouble(exactSL, g_digits);

   double currentTP = PositionGetDouble(POSITION_TP);
   double currentSL = PositionGetDouble(POSITION_SL);

   if(MathAbs(currentTP - exactTP) > (g_point * 0.1) || MathAbs(currentSL - exactSL) > (g_point * 0.1))
   {
      g_trade.SetExpertMagicNumber(InpMagicBot);
      g_trade.PositionModify(posTicket, exactSL, exactTP);
      Print(StringFormat("⚡ [KALIBRASI PRESISI] Tiket: #%I64d | Entry: %.3f | TP: %.3f | SL: %.3f", posTicket, exactPrice, exactTP, exactSL));
   }
}

//+------------------------------------------------------------------+
//| [8] Eksekutor Order                                              |
//+------------------------------------------------------------------+
void OpenZeroBotOrder(ENUM_POSITION_TYPE type, double lot)
{
   lot = NormalizeLotSize(lot);
   double dist = (InpTargetDistance > 0) ? InpTargetDistance : 1.0;
   g_trade.SetExpertMagicNumber(InpMagicBot);

   if(type == POSITION_TYPE_BUY)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double tp  = NormalizeDouble(ask + dist, g_digits);
      double sl  = NormalizeDouble(ask - dist, g_digits);
      g_trade.Buy(lot, _Symbol, ask, sl, tp, StringFormat("ZeroBot BUY Stp%d", g_currentStep));
   }
   else
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double tp  = NormalizeDouble(bid - dist, g_digits);
      double sl  = NormalizeDouble(bid + dist, g_digits);
      g_trade.Sell(lot, _Symbol, bid, sl, tp, StringFormat("ZeroBot SELL Stp%d", g_currentStep));
   }
}

//+------------------------------------------------------------------+
//| [9] Pengaman Darurat: Kunci Hedge 1:1                            |
//+------------------------------------------------------------------+
void ExecuteEmergencyHedge()
{
   double buyLots = 0, sellLots = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol)
      {
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
            buyLots += PositionGetDouble(POSITION_VOLUME);
         else
            sellLots += PositionGetDouble(POSITION_VOLUME);
      }
   }

   double netLots = buyLots - sellLots;
   if(MathAbs(netLots) < 0.00001) return;

   double hedgeLot = NormalizeLotSize(MathAbs(netLots));
   if(hedgeLot <= 0) return;

   g_trade.SetExpertMagicNumber(0);
   if(netLots > 0)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      g_trade.Sell(hedgeLot, _Symbol, bid, 0, 0, "EMERGENCY HEDGE 1:1");
   }
   else
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      g_trade.Buy(hedgeLot, _Symbol, ask, 0, 0, "EMERGENCY HEDGE 1:1");
   }
   Alert("🔒 AKUN DIKUNCI HEDGE 1:1! Silakan pantau untuk penyelesaian manual.");
}

//+------------------------------------------------------------------+
//| [10] Helper & Status Teks Minimalis                              |
//+------------------------------------------------------------------+
int CountBotPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicBot)
         count++;
   }

   // Auto Reset status jika operator telah menutup posisi manual
   if(count == 0 && g_isHedgeLocked)
   {
      g_isHedgeLocked = false;
      g_currentStep   = 1;
      g_currentBotLot = InpStartLot;
      Print("🔄 Siklus direset oleh operator. Robot kembali aktif!");
   }

   return count;
}

void UpdateChartComment()
{
   string status = "";
   if(!InpEnableBot)
      status = "NONAKTIF";
   else if(g_isHedgeLocked)
      status = "🔒 TERKUNCI HEDGE 1:1 (STEP 6 HIT)";
   else if(CountBotPositions() == 0)
      status = "STANDBY (Menunggu Crossing Level 0)";
   else
      status = StringFormat("AKTIF - STEP %d/%d (Lot: %.2f)", g_currentStep, InpMaxSteps, g_currentBotLot);

   Comment(StringFormat(
      "===========================================\n"
      " 🛡️ ZERO-LEVEL REVERSE BOT v5.0 (MINIMALIS)\n"
      "===========================================\n"
      " Simbol   : %s\n"
      " Status   : %s\n"
      " Jarak TP : +$%.2f (10 Pips)\n"
      " Jarak SL : -$%.2f (10 Pips)\n"
      " Magic ID : %I64d\n"
      "===========================================",
      _Symbol, status, InpTargetDistance, InpTargetDistance, InpMagicBot
   ));
}

ENUM_ORDER_TYPE_FILLING GetOptimalFilling(string symbol)
{
   uint filling = (uint)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
   if((filling & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
   return ORDER_FILLING_RETURN;
}

double NormalizeLotSize(double lot)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(stepLot <= 0) stepLot = 0.01;
   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);
   return NormalizeDouble(MathRound(lot / stepLot) * stepLot, 2);
}
//+------------------------------------------------------------------+
