//+------------------------------------------------------------------+
//|                                                   JaringEmas.mq5 |
//|  100% Dual-Direction: Split Fresh & Recovery Martingale          |
//|  Candle Close Engine + Dynamic Candle Range Overlay + Watchdog   |
//|  Auto-Lot Scaler ($1000 = 0.01) + Smart Margin Guard v14.00     |
//|                                      https://cindo.pages.dev     |
//+------------------------------------------------------------------+
#property copyright   "Mochamad Tabrani & Antigravity AI"
#property link        "https://cindo.pages.dev"
#property version     "14.00"
#property description "Dual-Direction Martingale with Dynamic Balance Auto-Lot Scaler & Margin Guard"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| [0] Enumerasi Status Posisi & Aksi                               |
//+------------------------------------------------------------------+
enum ENUM_POS_STATUS
{
   STATUS_FRESH     = 0, // Posisi FRESH (Compounding Saat Profit)
   STATUS_RECOVERY  = 1  // Posisi RECOVERY (Martingale Pemulihan Rugi)
};

enum ENUM_MAX_STEP_ACTION
{
   ACTION_CLOSE_ALL       = 0, // 🛑 Tutup Semua Posisi (Cut Loss Bersih - Aman dari SO)
   ACTION_STOP_NEW_ORDER  = 1  // 🔒 Kunci Bot (Biarkan posisi tersisa menyentuh SL/TP)
};

//+------------------------------------------------------------------+
//| [1] Parameter Input                                              |
//+------------------------------------------------------------------+
input group "=== [1] MANAJEMEN AUTO-LOT & SALDO ==="
input bool                  InpUseAutoLot         = true;              // 💰 Gunakan Auto-Lot Berdasarkan Saldo?
input double                InpBalancePerMinLot   = 1000.0;            // 💵 Saldo Per 0.01 Lot ($1000=0.01, $2000=0.02, dst)
input double                InpManualLot          = 0.01;              // ⚙️ Lot Manual (Hanya aktif jika Auto-Lot = false)

input group "=== [2] STRATEGI UTAMA & MARTINGALE ==="
input bool                  InpEnableBot          = true;              // 🤖 Aktifkan Robot Otomatis?
input double                InpLotMultiplier      = 2.0;               // Faktor Pengali Martingale (2.0x)
input int                   InpMaxFreshSteps      = 3;                 // 🚀 Batas Max Step Marti PROFIT FRESH (e.g. 1->2->3)
input int                   InpMaxRecoverySteps   = 8;                 // 🛑 Batas Max Level RECOVERY (Level 1 s/d Level 8)
input double                InpTargetDistance     = 1.0;               // Jarak TP & SL Presisi ($1.00 = 10 Pips XAUUSD)
input bool                  InpOpenOppositeFresh  = true;              // Buka FRESH Lawan saat FRESH Kena SL? (Poin 2)
input bool                  InpReopenAfterTP      = false;             // Buka Langsung setelah Recovery TP? (false = Tunggu Candle Baru)
input ENUM_MAX_STEP_ACTION  InpMaxStepAction      = ACTION_CLOSE_ALL;  // 🛡️ Aksi jika Max Step Hit (Cegah Stop Out)

input group "=== [3] FITUR INDIKATOR RANGE CANDLE ==="
input bool                  InpShowCandleRange    = true;              // 📊 Tampilkan Range (Bull di Bawah, Bear di Atas)?
input int                   InpCandleRangeBars    = 5;                 // 🔢 Jumlah Candle ke Belakang (1 = Candle Sebelum Live Saja)

input group "=== [4] PELINDUNG PASAR & MARGIN ==="
input int                   InpMaxSpread          = 0;                 // Batas Maksimal Spread (0 = Nonaktif / Bebas Spread)
input bool                  InpAvoidRollover      = false;             // 🛑 Hindari Trading Jam Rollover (23:55 - 00:10)?
input double                InpDailyProfitTarget  = 0.0;               // 🎯 Target Profit Harian ($) (0 = Nonaktif)
input double                InpDailyMaxLoss       = 0.0;               // 🛑 Batas Rugi Harian ($) (0 = Nonaktif)

input group "=== [5] NOTIFIKASI & BROKER ==="
input bool                  InpEnableAlert        = true;              // Popup Alert di Layar MT5?
input bool                  InpEnablePush         = false;             // Notifikasi ke HP (MetaQuotes ID)?
input int                   InpSlippage           = 50;                // Toleransi Slippage (pts)
input long                  InpMagicBot           = 888100;            // Magic Number Khusus Bot Ini

//+------------------------------------------------------------------+
//| [2] Variabel Global                                              |
//+------------------------------------------------------------------+
double            g_point;
int               g_digits;

// State Sisi BUY
int               g_buyStep         = 1;
double            g_buyLot          = 0.01;
ENUM_POS_STATUS   g_buyStatus       = STATUS_FRESH;
bool              g_isBuyLocked     = false;

// State Sisi SELL
int               g_sellStep        = 1;
double            g_sellLot         = 0.01;
ENUM_POS_STATUS   g_sellStatus      = STATUS_FRESH;
bool              g_isSellLocked    = false;

// Timing Bar Baru
datetime          g_lastBarTime     = 0;

// Prefix Objek Range Candle
const string      PREFIX_CRANGE     = "CRANGE_";

// Circuit Breaker State
bool              g_isCircuitBreakerTripped = false;
ulong             g_lastManagedDeal        = 0;
CTrade            g_trade;

//+------------------------------------------------------------------+
//| [3] Lifecycle Inisialisasi                                       |
//+------------------------------------------------------------------+
int OnInit()
{
   g_point        = _Point;
   g_digits       = _Digits;

   g_lastManagedDeal = 0;
   g_isCircuitBreakerTripped = false;

   // Simpan waktu bar saat ini agar menunggu candle berikutnya selesai
   g_lastBarTime  = iTime(_Symbol, _Period, 0);

   g_trade.SetExpertMagicNumber(InpMagicBot);
   g_trade.SetDeviationInPoints(InpSlippage);

   // Cek Izin Algo Trading di Toolbar MT5
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      Alert("⚠️ PERINGATAN: Tombol 'Algo Trading' di toolbar atas MT5 masih MATI (Merah)! Klik agar HIJAU.");
      Print("⚠️ [PERINGATAN] Tombol Algo Trading MT5 belum diaktifkan!");
   }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
   {
      Alert("⚠️ PERINGATAN: Akun ini dalam mode Read-Only / Investor Password!");
      Print("⚠️ [PERINGATAN] Akun tidak mengizinkan eksekusi order!");
   }

   ENUM_ACCOUNT_MARGIN_MODE marginMode = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(marginMode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Alert("⚠️ PERINGATAN: Akun MT5 bertipe NETTING! Strategi 2 arah simultan memerlukan akun tipe HEDGING.");
   }

   RestoreStateFromOpenPositions();

   // Gambar teks range candle saat EA pertama kali dipasang
   DrawCandleRangeLabels();

   Print("=== JaringEmas v14.00 (Auto-Lot Scaler & Robust Marti) Aktif ===");
   UpdateChartComment();
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   // Hapus semua objek teks range candle saat bot dilepas
   ObjectsDeleteAll(0, PREFIX_CRANGE);
   Comment("");
   Print("=== JaringEmas Dihentikan ===");
}

//+------------------------------------------------------------------+
//| [4] Eksekusi Tiap Tick                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   // [WATCHDOG]: Memastikan 100% posisi terpasang SL & TP presisi
   EnforcePositionTPSL();

   CheckAutoResetLocks();

   if(!CheckDailyCircuitBreaker())
   {
      UpdateChartComment();
      return;
   }

   if(InpEnableBot && !g_isCircuitBreakerTripped)
   {
      CheckDirectCandleClose();
   }

   UpdateChartComment();
}

//+------------------------------------------------------------------+
//| [FITUR VISUAL]: Menggambar Range (Bull di Bawah, Bear di Atas)   |
//+------------------------------------------------------------------+
void DrawCandleRangeLabels()
{
   if(!InpShowCandleRange) return;

   int barsToDraw = MathMax(1, InpCandleRangeBars);

   for(int i = 1; i <= barsToDraw; i++)
   {
      datetime barTime = iTime(_Symbol, _Period, i);
      if(barTime == 0) continue;

      double high  = iHigh(_Symbol, _Period, i);
      double low   = iLow(_Symbol, _Period, i);
      double open  = iOpen(_Symbol, _Period, i);
      double close = iClose(_Symbol, _Period, i);
      double range = high - low;

      // Jarak offset proporsional agar tidak menabrak sumbu candle
      double offset = MathMax(range * 0.15, 25 * g_point);

      double textPrice;
      ENUM_ANCHOR_POINT anchorPos;
      color txtColor;

      // Candle Bullish (Hijau/Naik): Letakkan DI BAWAH Low candle
      if(close >= open)
      {
         textPrice = low - offset;
         anchorPos = ANCHOR_UPPER;
         txtColor  = clrLime;
      }
      // Candle Bearish (Merah/Turun): Letakkan DI ATAS High candle
      else
      {
         textPrice = high + offset;
         anchorPos = ANCHOR_LOWER;
         txtColor  = clrTomato;
      }

      string objName = StringFormat("%s%I64d", PREFIX_CRANGE, (long)barTime);

      if(ObjectFind(0, objName) < 0)
      {
         ObjectCreate(0, objName, OBJ_TEXT, 0, barTime, textPrice);
      }
      else
      {
         ObjectMove(0, objName, 0, barTime, textPrice);
      }

      string txt = StringFormat("R: $%.2f", range);

      ObjectSetString(0, objName, OBJPROP_TEXT, txt);
      ObjectSetInteger(0, objName, OBJPROP_COLOR, txtColor);
      ObjectSetInteger(0, objName, OBJPROP_FONTSIZE, 8);
      ObjectSetString(0, objName, OBJPROP_FONT, "Arial Bold");
      ObjectSetInteger(0, objName, OBJPROP_ANCHOR, anchorPos);
      ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, objName, OBJPROP_HIDDEN, true);
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| [WATCHDOG] Penjamin 100% SL & TP Terpasang                       |
//+------------------------------------------------------------------+
void EnforcePositionTPSL()
{
   double dist = GetSafeTargetDistance();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicBot)
      {
         double sl = PositionGetDouble(POSITION_SL);
         double tp = PositionGetDouble(POSITION_TP);
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         long type = PositionGetInteger(POSITION_TYPE);

         if(sl <= 0.0 || tp <= 0.0)
         {
            double exactTP = (type == POSITION_TYPE_BUY) ? NormalizeDouble(openPrice + dist, g_digits) : NormalizeDouble(openPrice - dist, g_digits);
            double exactSL = (type == POSITION_TYPE_BUY) ? NormalizeDouble(openPrice - dist, g_digits) : NormalizeDouble(openPrice + dist, g_digits);

            g_trade.SetExpertMagicNumber(InpMagicBot);
            g_trade.PositionModify(ticket, exactSL, exactTP);
         }
      }
   }
}

double GetSafeTargetDistance()
{
   double dist = (InpTargetDistance > 0) ? InpTargetDistance : 1.0;
   double stopLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * g_point;
   if(stopLevel > 0 && dist < (stopLevel + (2 * g_point)))
   {
      dist = stopLevel + (2 * g_point);
   }
   return dist;
}

//+------------------------------------------------------------------+
//| [HITUNG LOT DINAMIS]: Saldo $1000 = 0.01, $2000 = 0.02           |
//+------------------------------------------------------------------+
double GetFreshStartLot()
{
   if(!InpUseAutoLot || InpBalancePerMinLot <= 0.0)
      return NormalizeLotSize(InpManualLot);

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   int multiplier = (int)MathFloor(balance / InpBalancePerMinLot);
   if(multiplier < 1) multiplier = 1;

   double autoLot = multiplier * 0.01;
   return NormalizeLotSize(autoLot);
}

//+------------------------------------------------------------------+
//| [5] Mesin Pemicu: Direct Candle Close Engine                     |
//+------------------------------------------------------------------+
void CheckDirectCandleClose()
{
   datetime currentBarTime = iTime(_Symbol, _Period, 0);
   if(currentBarTime == 0) return;

   if(currentBarTime == g_lastBarTime) return; // Belum ada candle baru

   if(IsRolloverTime() || !IsSpreadOK()) return;

   // Baca candle [1] yang baru saja selesai
   double open1  = iOpen(_Symbol, _Period, 1);
   double close1 = iClose(_Symbol, _Period, 1);

   if(open1 <= 0.0 || close1 <= 0.0) return;

   g_lastBarTime = currentBarTime;

   // Perbarui gambar angka range candle di chart
   DrawCandleRangeLabels();

   int buyCount  = CountBotPositions(POSITION_TYPE_BUY);
   int sellCount = CountBotPositions(POSITION_TYPE_SELL);

   PrintFormat("🔔 [CANDLE BARU] Waktu: %s | Open[1]: %.*f | Close[1]: %.*f",
               TimeToString(currentBarTime, TIME_MINUTES), g_digits, open1, g_digits, close1);

   // 1. CANDLE TURUN (MERAH) -> BUKA SELL FRESH
   if(close1 < open1)
   {
      PrintFormat("🔻 [CANDLE TURUN] Close (%.*f) < Open (%.*f) -> Memicu SELL FRESH!", g_digits, close1, g_digits, open1);

      if(sellCount == 0 && !g_isSellLocked && g_sellStatus == STATUS_FRESH)
      {
         g_sellLot  = GetFreshStartLot();
         g_sellStep = 1;
         OpenZeroBotOrder(POSITION_TYPE_SELL, g_sellLot, g_sellStep, STATUS_FRESH);
      }
   }
   // 2. CANDLE NAIK (HIJAU) -> BUKA BUY FRESH
   else if(close1 > open1)
   {
      PrintFormat("🚀 [CANDLE NAIK] Close (%.*f) > Open (%.*f) -> Memicu BUY FRESH!", g_digits, close1, g_digits, open1);

      if(buyCount == 0 && !g_isBuyLocked && g_buyStatus == STATUS_FRESH)
      {
         g_buyLot   = GetFreshStartLot();
         g_buyStep  = 1;
         OpenZeroBotOrder(POSITION_TYPE_BUY, g_buyLot, g_buyStep, STATUS_FRESH);
      }
   }
}

//+------------------------------------------------------------------+
//| [6] Transaksi: Mesin Fresh Compounding & Recovery Martingale     |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   ulong dealTicket = trans.deal;
   if(dealTicket == 0 || !HistoryDealSelect(dealTicket)) return;

   long   dealEntry  = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   long   dealType   = HistoryDealGetInteger(dealTicket, DEAL_TYPE);
   string sym        = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
   long   magic      = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
   long   dealReason = HistoryDealGetInteger(dealTicket, DEAL_REASON);

   if(sym != _Symbol || magic != InpMagicBot) return;

   // 1. Kalibrasi Instan saat Order Terisi
   if(dealEntry == DEAL_ENTRY_IN)
   {
      ulong posTicket   = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      double exactPrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
      ENUM_POSITION_TYPE pType = (dealType == DEAL_TYPE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;

      CalibratePositionTPSL(posTicket, exactPrice, pType);
      return;
   }

   // 2. Eksekusi saat Order Tertutup (DEAL_ENTRY_OUT)
   if(dealEntry == DEAL_ENTRY_OUT)
   {
      if(dealTicket == g_lastManagedDeal) return;
      g_lastManagedDeal = dealTicket;

      double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
      ENUM_POSITION_TYPE origPosType = (dealType == DEAL_TYPE_SELL) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;

      bool isTP = (dealReason == DEAL_REASON_TP || (dealReason != DEAL_REASON_SL && profit > 0));
      bool isSL = (dealReason == DEAL_REASON_SL || (dealReason != DEAL_REASON_TP && profit < 0));

      // ========================================================
      // [A] SISI BUY
      // ========================================================
      if(origPosType == POSITION_TYPE_BUY)
      {
         // --- KASUS: BUY TAKE PROFIT ---
         if(isTP)
         {
            if(g_buyStatus == STATUS_FRESH)
            {
               // 🚀 MARTINGALE PROFIT FRESH (COMPOUNDING)
               if(g_buyStep < InpMaxFreshSteps)
               {
                  int nextStep   = g_buyStep + 1;
                  double nextLot = NormalizeLotSize(g_buyLot * InpLotMultiplier);

                  PrintFormat("🚀 [BUY FRESH TP HIT!] Profit: $%.2f. Marti Profit ke BUY FRESH Step %d (Lot: %.2f)!",
                              profit, nextStep, nextLot);
                  if(InpEnableAlert) Alert(StringFormat("BUY Fresh TP! Lanjut Marti Profit Lot: %.2f", nextLot));

                  if(InpEnableBot && !g_isBuyLocked)
                  {
                     if(OpenZeroBotOrder(POSITION_TYPE_BUY, nextLot, nextStep, STATUS_FRESH))
                     {
                        g_buyStep   = nextStep;
                        g_buyLot    = nextLot;
                        g_buyStatus = STATUS_FRESH;
                     }
                  }
               }
               else
               {
                  double freshLot = GetFreshStartLot();
                  PrintFormat("👑 [BUY MAX FRESH %d HIT!] Profit: $%.2f. Panen Profit! Reset ke Fresh Step 1 (Lot: %.2f)",
                              InpMaxFreshSteps, profit, freshLot);

                  g_buyStep   = 1;
                  g_buyLot    = freshLot;
                  g_buyStatus = STATUS_FRESH;

                  if(InpEnableBot && !g_isBuyLocked && InpReopenAfterTP)
                     OpenZeroBotOrder(POSITION_TYPE_BUY, g_buyLot, g_buyStep, STATUS_FRESH);
               }
            }
            else // g_buyStatus == STATUS_RECOVERY
            {
               double freshLot = GetFreshStartLot();
               PrintFormat("🎉 [BUY RECOVERY TP HIT!] Recovery Tuntas! Profit: $%.2f. Reset ke Fresh Lot: %.2f",
                           profit, freshLot);
               if(InpEnableAlert) Alert(StringFormat("BUY Recovery Tuntas! Reset ke Fresh Lot: %.2f", freshLot));

               g_buyStatus = STATUS_FRESH;
               g_buyStep   = 1;
               g_buyLot    = freshLot;

               if(InpEnableBot && !g_isBuyLocked && InpReopenAfterTP)
                  OpenZeroBotOrder(POSITION_TYPE_BUY, g_buyLot, g_buyStep, STATUS_FRESH);
            }
         }
         // --- KASUS: BUY STOP LOSS ---
         else if(isSL)
         {
            if(g_buyStatus == STATUS_FRESH)
            {
               // FRESH (misal 0.01) SL -> Mulai RECOVERY LEVEL 1 (Lot 0.02)
               double nextLot = NormalizeLotSize(g_buyLot * InpLotMultiplier);

               PrintFormat("🛑 [BUY FRESH SL] Mulai RECOVERY Level 1 (Lot: %.2f) & Buka SELL %.2f FRESH", nextLot, nextLot);
               if(InpEnableAlert) Alert(StringFormat("BUY SL! Buka BUY %.2f RECOV Lvl 1 & SELL %.2f FRESH", nextLot, nextLot));

               if(InpEnableBot && !g_isBuyLocked)
               {
                  if(OpenZeroBotOrder(POSITION_TYPE_BUY, nextLot, 1, STATUS_RECOVERY))
                  {
                     g_buyStatus = STATUS_RECOVERY;
                     g_buyStep   = 1;
                     g_buyLot    = nextLot;

                     if(InpOpenOppositeFresh && CountBotPositions(POSITION_TYPE_SELL) == 0 && !g_isSellLocked)
                     {
                        if(OpenZeroBotOrder(POSITION_TYPE_SELL, nextLot, 1, STATUS_FRESH))
                        {
                           g_sellStatus = STATUS_FRESH;
                           g_sellStep   = 1;
                           g_sellLot    = nextLot;
                        }
                     }
                  }
               }
            }
            else // g_buyStatus == STATUS_RECOVERY
            {
               // Jika level saat ini sudah mencapai Max Recovery Steps (e.g. 8)
               if(g_buyStep >= InpMaxRecoverySteps)
               {
                  HandleMaxStepReached("BUY");
                  return;
               }

               int nextStep   = g_buyStep + 1;
               double nextLot = NormalizeLotSize(g_buyLot * InpLotMultiplier);

               PrintFormat("🛑 [BUY RECOVERY SL] Melanjutkan ke BUY RECOVERY Level %d (Lot: %.2f)...", nextStep, nextLot);
               if(InpEnableBot && !g_isBuyLocked)
               {
                  if(OpenZeroBotOrder(POSITION_TYPE_BUY, nextLot, nextStep, STATUS_RECOVERY))
                  {
                     g_buyStep = nextStep;
                     g_buyLot  = nextLot;
                  }
                  else
                  {
                     PrintFormat("🚨 [GAGAL ORDER] Gagal membuka BUY RECOVERY Level %d (Lot: %.2f)! Cek Free Margin akun.", nextStep, nextLot);
                     if(InpEnableAlert) Alert(StringFormat("Gagal Order BUY RECOVERY Level %d (Lot: %.2f)! Periksa Saldo.", nextStep, nextLot));
                  }
               }
            }
         }
      }
      // ========================================================
      // [B] SISI SELL
      // ========================================================
      else if(origPosType == POSITION_TYPE_SELL)
      {
         // --- KASUS: SELL TAKE PROFIT ---
         if(isTP)
         {
            if(g_sellStatus == STATUS_FRESH)
            {
               // 🚀 MARTINGALE PROFIT FRESH (COMPOUNDING)
               if(g_sellStep < InpMaxFreshSteps)
               {
                  int nextStep   = g_sellStep + 1;
                  double nextLot = NormalizeLotSize(g_sellLot * InpLotMultiplier);

                  PrintFormat("🚀 [SELL FRESH TP HIT!] Profit: $%.2f. Marti Profit ke SELL FRESH Step %d (Lot: %.2f)!",
                              profit, nextStep, nextLot);
                  if(InpEnableAlert) Alert(StringFormat("SELL Fresh TP! Lanjut Marti Profit Lot: %.2f", nextLot));

                  if(InpEnableBot && !g_isSellLocked)
                  {
                     if(OpenZeroBotOrder(POSITION_TYPE_SELL, nextLot, nextStep, STATUS_FRESH))
                     {
                        g_sellStep   = nextStep;
                        g_sellLot    = nextLot;
                        g_sellStatus = STATUS_FRESH;
                     }
                  }
               }
               else
               {
                  double freshLot = GetFreshStartLot();
                  PrintFormat("👑 [SELL MAX FRESH %d HIT!] Profit: $%.2f. Panen Profit! Reset ke Fresh Step 1 (Lot: %.2f)",
                              InpMaxFreshSteps, profit, freshLot);

                  g_sellStep   = 1;
                  g_sellLot    = freshLot;
                  g_sellStatus = STATUS_FRESH;

                  if(InpEnableBot && !g_isSellLocked && InpReopenAfterTP)
                     OpenZeroBotOrder(POSITION_TYPE_SELL, g_sellLot, g_sellStep, STATUS_FRESH);
               }
            }
            else // g_sellStatus == STATUS_RECOVERY
            {
               double freshLot = GetFreshStartLot();
               PrintFormat("🎉 [SELL RECOVERY TP HIT!] Recovery Tuntas! Profit: $%.2f. Reset ke Fresh Lot: %.2f",
                           profit, freshLot);
               if(InpEnableAlert) Alert(StringFormat("SELL Recovery Tuntas! Reset ke Fresh Lot: %.2f", freshLot));

               g_sellStatus = STATUS_FRESH;
               g_sellStep   = 1;
               g_sellLot    = freshLot;

               if(InpEnableBot && !g_isSellLocked && InpReopenAfterTP)
                  OpenZeroBotOrder(POSITION_TYPE_SELL, g_sellLot, g_sellStep, STATUS_FRESH);
            }
         }
         // --- KASUS: SELL STOP LOSS ---
         else if(isSL)
         {
            if(g_sellStatus == STATUS_FRESH)
            {
               // FRESH (misal 0.01) SL -> Mulai RECOVERY LEVEL 1 (Lot 0.02)
               double nextLot = NormalizeLotSize(g_sellLot * InpLotMultiplier);

               PrintFormat("🛑 [SELL FRESH SL] Mulai RECOVERY Level 1 (Lot: %.2f) & Buka BUY %.2f FRESH", nextLot, nextLot);
               if(InpEnableAlert) Alert(StringFormat("SELL SL! Buka SELL %.2f RECOV Lvl 1 & BUY %.2f FRESH", nextLot, nextLot));

               if(InpEnableBot && !g_isSellLocked)
               {
                  if(OpenZeroBotOrder(POSITION_TYPE_SELL, nextLot, 1, STATUS_RECOVERY))
                  {
                     g_sellStatus = STATUS_RECOVERY;
                     g_sellStep   = 1;
                     g_sellLot    = nextLot;

                     if(InpOpenOppositeFresh && CountBotPositions(POSITION_TYPE_BUY) == 0 && !g_isBuyLocked)
                     {
                        if(OpenZeroBotOrder(POSITION_TYPE_BUY, nextLot, 1, STATUS_FRESH))
                        {
                           g_buyStatus = STATUS_FRESH;
                           g_buyStep   = 1;
                           g_buyLot    = nextLot;
                        }
                     }
                  }
               }
            }
            else // g_sellStatus == STATUS_RECOVERY
            {
               // Jika level saat ini sudah mencapai Max Recovery Steps (e.g. 8)
               if(g_sellStep >= InpMaxRecoverySteps)
               {
                  HandleMaxStepReached("SELL");
                  return;
               }

               int nextStep   = g_sellStep + 1;
               double nextLot = NormalizeLotSize(g_sellLot * InpLotMultiplier);

               PrintFormat("🛑 [SELL RECOVERY SL] Melanjutkan ke SELL RECOVERY Level %d (Lot: %.2f)...", nextStep, nextLot);
               if(InpEnableBot && !g_isSellLocked)
               {
                  if(OpenZeroBotOrder(POSITION_TYPE_SELL, nextLot, nextStep, STATUS_RECOVERY))
                  {
                     g_sellStep = nextStep;
                     g_sellLot  = nextLot;
                  }
                  else
                  {
                     PrintFormat("🚨 [GAGAL ORDER] Gagal membuka SELL RECOVERY Level %d (Lot: %.2f)! Cek Free Margin akun.", nextStep, nextLot);
                     if(InpEnableAlert) Alert(StringFormat("Gagal Order SELL RECOVERY Level %d (Lot: %.2f)! Periksa Saldo.", nextStep, nextLot));
                  }
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| [7] Penanganan Anti-Stop Out                                     |
//+------------------------------------------------------------------+
void HandleMaxStepReached(string side)
{
   PrintFormat("🚨 [%s MAX RECOVERY LEVEL TERCAPAI!] Mengaktifkan Protokol Proteksi...", side);
   if(InpEnableAlert) Alert(StringFormat("%s Max Recovery Level %d Tercapai!", side, InpMaxRecoverySteps));
   if(InpEnablePush)  SendNotification(StringFormat("%s Max Recovery Level %d Tercapai!", side, InpMaxRecoverySteps));

   if(side == "BUY")  g_isBuyLocked  = true;
   if(side == "SELL") g_isSellLocked = true;

   if(InpMaxStepAction == ACTION_CLOSE_ALL)
   {
      Print("🛡️ [ANTI-STOP OUT] Menutup seluruh posisi untuk melindungi modal akun dari Margin Call!");
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicBot)
         {
            g_trade.PositionClose(ticket);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| [8] Kalibrasi Pasca-Eksekusi                                     |
//+------------------------------------------------------------------+
void CalibratePositionTPSL(ulong posTicket, double exactPrice, ENUM_POSITION_TYPE posType)
{
   if(!PositionSelectByTicket(posTicket)) return;

   double dist = GetSafeTargetDistance();
   double exactTP = (posType == POSITION_TYPE_BUY) ? (exactPrice + dist) : (exactPrice - dist);
   double exactSL = (posType == POSITION_TYPE_BUY) ? (exactPrice - dist) : (exactPrice + dist);
   exactTP = NormalizeDouble(exactTP, g_digits);
   exactSL = NormalizeDouble(exactSL, g_digits);

   double currentTP = PositionGetDouble(POSITION_TP);
   double currentSL = PositionGetDouble(POSITION_SL);

   if(MathAbs(currentTP - exactTP) > (g_point * 0.5) || MathAbs(currentSL - exactSL) > (g_point * 0.5))
   {
      g_trade.SetExpertMagicNumber(InpMagicBot);
      g_trade.PositionModify(posTicket, exactSL, exactTP);
   }
}

//+------------------------------------------------------------------+
//| [9] Eksekutor Order dengan Multi-Filling, Retry & Margin Guard    |
//+------------------------------------------------------------------+
bool OpenZeroBotOrder(ENUM_POSITION_TYPE type, double lot, int step, ENUM_POS_STATUS status)
{
   lot = NormalizeLotSize(lot);
   double dist = GetSafeTargetDistance();
   g_trade.SetExpertMagicNumber(InpMagicBot);

   string statusStr = (status == STATUS_FRESH) ? "FRESH" : "RECOV";
   string commentStr = StringFormat("ZB %s %s Lvl%d", (type == POSITION_TYPE_BUY ? "BUY" : "SELL"), statusStr, step);

   // [1] Smart Margin Check
   double checkPrice = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   ENUM_ORDER_TYPE oType = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double reqMargin = 0.0;

   if(OrderCalcMargin(oType, _Symbol, lot, checkPrice, reqMargin))
   {
      double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      if(reqMargin > freeMargin)
      {
         string msg = StringFormat("⛔ [MARGIN KURANG!] %s Level %d (Lot: %.2f) butuh margin $%.2f, Free Margin sisa $%.2f!",
                                   (type == POSITION_TYPE_BUY ? "BUY" : "SELL"), step, lot, reqMargin, freeMargin);
         Print(msg);
         if(InpEnableAlert) Alert(msg);
         return false;
      }
   }

   bool success = false;

   // [2] Eksekusi Order dengan Retry Loop (Maksimal 3 Kali Coba)
   for(int attempt = 1; attempt <= 3; attempt++)
   {
      ResetLastError();
      if(type == POSITION_TYPE_BUY)
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double tp  = NormalizeDouble(ask + dist, g_digits);
         double sl  = NormalizeDouble(ask - dist, g_digits);

         success = g_trade.Buy(lot, _Symbol, ask, sl, tp, commentStr);
         if(!success)
         {
            g_trade.SetTypeFilling(ORDER_FILLING_IOC);
            success = g_trade.Buy(lot, _Symbol, ask, sl, tp, commentStr);
         }
         if(!success)
         {
            g_trade.SetTypeFilling(ORDER_FILLING_RETURN);
            success = g_trade.Buy(lot, _Symbol, ask, sl, tp, commentStr);
         }
      }
      else
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double tp  = NormalizeDouble(bid - dist, g_digits);
         double sl  = NormalizeDouble(bid + dist, g_digits);

         success = g_trade.Sell(lot, _Symbol, bid, sl, tp, commentStr);
         if(!success)
         {
            g_trade.SetTypeFilling(ORDER_FILLING_IOC);
            success = g_trade.Sell(lot, _Symbol, bid, sl, tp, commentStr);
         }
         if(!success)
         {
            g_trade.SetTypeFilling(ORDER_FILLING_RETURN);
            success = g_trade.Sell(lot, _Symbol, bid, sl, tp, commentStr);
         }
      }

      if(success) break;
      Sleep(200);
   }

   if(success)
   {
      PrintFormat("✅ Order %s %s Level %d (Lot: %.2f) BERHASIL DIBUKA!",
                  (type == POSITION_TYPE_BUY ? "BUY" : "SELL"), statusStr, step, lot);
      EnforcePositionTPSL();
   }
   else
   {
      uint retCode = g_trade.ResultRetcode();
      string retDesc = g_trade.ResultRetcodeDescription();
      PrintFormat("❌ Gagal Order %s %s Level %d (Lot: %.2f) - Retcode: %u (%s)",
                  (type == POSITION_TYPE_BUY ? "BUY" : "SELL"), statusStr, step, lot, retCode, retDesc);

      if(retCode == 10019)
         Alert(StringFormat("❌ [NO MONEY] Saldo/Margin tidak cukup untuk membuka Level %d (Lot: %.2f)!", step, lot));
      else if(retCode == 10014 || retCode == 10043)
         Alert(StringFormat("❌ [LIMIT LOT] Lot %.2f melampaui batas maksimal broker!", lot));
   }
   return success;
}

//+------------------------------------------------------------------+
//| [10] Pelindung Senior                                            |
//+------------------------------------------------------------------+
bool IsRolloverTime()
{
   if(!InpAvoidRollover) return false;
   MqlDateTime dt;
   TimeCurrent(dt);
   if((dt.hour == 23 && dt.min >= 55) || (dt.hour == 0 && dt.min <= 10))
      return true;
   return false;
}

bool IsSpreadOK()
{
   if(InpMaxSpread <= 0) return true;
   long currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (currentSpread <= InpMaxSpread);
}

void RestoreStateFromOpenPositions()
{
   double baseLot = GetFreshStartLot();
   g_buyStep      = 1;
   g_buyLot       = baseLot;
   g_buyStatus    = STATUS_FRESH;
   g_isBuyLocked  = false;

   g_sellStep     = 1;
   g_sellLot      = baseLot;
   g_sellStatus   = STATUS_FRESH;
   g_isSellLocked = false;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicBot)
      {
         long type = PositionGetInteger(POSITION_TYPE);
         double vol = PositionGetDouble(POSITION_VOLUME);
         string comment = PositionGetString(POSITION_COMMENT);

         if(type == POSITION_TYPE_BUY)
         {
            g_buyLot = vol;
            g_buyStatus = (StringFind(comment, "RECOV") >= 0) ? STATUS_RECOVERY : STATUS_FRESH;
            int stpPos = StringFind(comment, "Lvl");
            if(stpPos < 0) stpPos = StringFind(comment, "Stp");
            if(stpPos >= 0)
               g_buyStep = (int)StringToInteger(StringSubstr(comment, stpPos + 3));
         }
         else if(type == POSITION_TYPE_SELL)
         {
            g_sellLot = vol;
            g_sellStatus = (StringFind(comment, "RECOV") >= 0) ? STATUS_RECOVERY : STATUS_FRESH;
            int stpPos = StringFind(comment, "Lvl");
            if(stpPos < 0) stpPos = StringFind(comment, "Stp");
            if(stpPos >= 0)
               g_sellStep = (int)StringToInteger(StringSubstr(comment, stpPos + 3));
         }
      }
   }
}

double GetTodayProfit()
{
   datetime todayStart = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   if(!HistorySelect(todayStart, TimeCurrent())) return 0.0;

   double pnl = 0.0;
   int totalDeals = HistoryDealsTotal();
   for(int i = 0; i < totalDeals; i++)
   {
      ulong t = HistoryDealGetTicket(i);
      if(t > 0 && HistoryDealGetString(t, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(t, DEAL_MAGIC) == InpMagicBot)
      {
         if(HistoryDealGetInteger(t, DEAL_ENTRY) == DEAL_ENTRY_OUT)
         {
            pnl += HistoryDealGetDouble(t, DEAL_PROFIT) 
                 + HistoryDealGetDouble(t, DEAL_SWAP) 
                 + HistoryDealGetDouble(t, DEAL_COMMISSION);
         }
      }
   }
   return pnl;
}

bool CheckDailyCircuitBreaker()
{
   if(InpDailyProfitTarget <= 0.0 && InpDailyMaxLoss <= 0.0) return true;

   double todayPnl = GetTodayProfit();

   if(InpDailyProfitTarget > 0.0 && todayPnl >= InpDailyProfitTarget)
   {
      if(!g_isCircuitBreakerTripped)
      {
         g_isCircuitBreakerTripped = true;
         string msg = StringFormat("🎉 [CIRCUIT BREAKER] Target Harian $%.2f Tercapai! Profit: $%.2f.", InpDailyProfitTarget, todayPnl);
         Print(msg);
         if(InpEnableAlert) Alert(msg);
      }
      return false;
   }

   if(InpDailyMaxLoss > 0.0 && todayPnl <= -InpDailyMaxLoss)
   {
      if(!g_isCircuitBreakerTripped)
      {
         g_isCircuitBreakerTripped = true;
         string msg = StringFormat("🛑 [CIRCUIT BREAKER] Batas Rugi Harian -$%.2f Terlewati! Loss: $%.2f.", InpDailyMaxLoss, todayPnl);
         Print(msg);
         if(InpEnableAlert) Alert(msg);
      }
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| [11] Helper & Status Dashboard                                   |
//+------------------------------------------------------------------+
int CountBotPositions(int type = -1)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicBot)
      {
         if(type == -1 || PositionGetInteger(POSITION_TYPE) == type)
            count++;
      }
   }
   return count;
}

void CheckAutoResetLocks()
{
   double baseLot = GetFreshStartLot();
   if(CountBotPositions(POSITION_TYPE_BUY) == 0 && g_isBuyLocked && !g_isCircuitBreakerTripped)
   {
      g_isBuyLocked = false;
      g_buyStep     = 1;
      g_buyLot      = baseLot;
      g_buyStatus   = STATUS_FRESH;
   }
   if(CountBotPositions(POSITION_TYPE_SELL) == 0 && g_isSellLocked && !g_isCircuitBreakerTripped)
   {
      g_isSellLocked = false;
      g_sellStep     = 1;
      g_sellLot      = baseLot;
      g_sellStatus   = STATUS_FRESH;
   }
}

void UpdateChartComment()
{
   string botStatus = InpEnableBot ? "AKTIF" : "NONAKTIF";
   if(g_isCircuitBreakerTripped)
      botStatus = "🔒 PAUSE (Circuit Breaker Harian Aktif)";

   int buyPos  = CountBotPositions(POSITION_TYPE_BUY);
   int sellPos = CountBotPositions(POSITION_TYPE_SELL);
   long curSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double todayPnl = GetTodayProfit();
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double currentFreshLot = GetFreshStartLot();

   string buyStatus = "";
   if(g_isBuyLocked)
      buyStatus = StringFormat("🔒 TERKUNCI (Max Recovery Level %d Hit)", InpMaxRecoverySteps);
   else if(buyPos > 0)
   {
      string sTag = (g_buyStatus == STATUS_FRESH) ? "FRESH" : "RECOV";
      buyStatus = StringFormat("AKTIF [%s] Lvl %d (Lot: %.2f)", sTag, g_buyStep, g_buyLot);
   }
   else
      buyStatus = StringFormat("STANDBY [FRESH] - Lot: %.2f", currentFreshLot);

   string sellStatus = "";
   if(g_isSellLocked)
      sellStatus = StringFormat("🔒 TERKUNCI (Max Recovery Level %d Hit)", InpMaxRecoverySteps);
   else if(sellPos > 0)
   {
      string sTag = (g_sellStatus == STATUS_FRESH) ? "FRESH" : "RECOV";
      sellStatus = StringFormat("AKTIF [%s] Lvl %d (Lot: %.2f)", sTag, g_sellStep, g_sellLot);
   }
   else
      sellStatus = StringFormat("STANDBY [FRESH] - Lot: %.2f", currentFreshLot);

   Comment(StringFormat(
      "===========================================================\n"
      " 🛡️ JARING EMAS v14.00 - AUTO-LOT BALANCE SCALER\n"
      "===========================================================\n"
      " Simbol        : %s | Timeframe: %s\n"
      " Saldo Akun    : $%.2f | Free Margin: $%.2f\n"
      " Lot Fresh Auto: %.2f (Per $%.0f Saldo = 0.01)\n"
      " Status Robot  : %s\n"
      " Pemicu Entry  : Direct Candle (Turun=SELL, Naik=BUY)\n"
      " Live Spread   : %d pts | PnL Hari Ini: $%.2f\n"
      "-----------------------------------------------------------\n"
      " 🟢 SISI BUY   : %s\n"
      " 🔴 SISI SELL  : %s\n"
      "-----------------------------------------------------------\n"
      " Max Fresh Stp : %d (Marti Profit Saat Menang)\n"
      " Max Recov Lvl : %d (Batas Toleransi SL)\n"
      " Multiplier    : %.1fx | TP/SL: $%.2f\n"
      " Magic Number  : %I64d\n"
      "===========================================================",
      _Symbol, EnumToString(_Period),
      balance, freeMargin,
      currentFreshLot, InpBalancePerMinLot,
      botStatus,
      curSpread, todayPnl,
      buyStatus, sellStatus,
      InpMaxFreshSteps,
      InpMaxRecoverySteps,
      InpLotMultiplier, InpTargetDistance,
      InpMagicBot
   ));
}

double NormalizeLotSize(double lot)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(stepLot <= 0) stepLot = 0.01;
   if(minLot <= 0)  minLot  = 0.01;
   if(maxLot <= 0)  maxLot  = 100.0;

   int lotDigits = 2;
   if(stepLot == 1.0) lotDigits = 0;
   else if(stepLot == 0.1) lotDigits = 1;
   else if(stepLot == 0.01) lotDigits = 2;
   else if(stepLot == 0.001) lotDigits = 3;

   double roundedLot = MathRound(lot / stepLot) * stepLot;
   roundedLot = MathMax(roundedLot, minLot);
   roundedLot = MathMin(roundedLot, maxLot);
   return NormalizeDouble(roundedLot, lotDigits);
}
//+------------------------------------------------------------------+
