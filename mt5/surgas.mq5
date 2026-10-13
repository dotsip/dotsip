//+------------------------------------------------------------------+
//|                                                 RiskRadarHUD.mq5 |
//|  Radar Risiko + Fast Bulk Close + One-Click Trading              |
//|  + Hedge 1:1 + Reverse + Auto Target (+) & Auto Cutloss (-)      |
//|  + [PRO v4] 100% FULL AUTO DIRECTIONAL CROSSING REVERSE BOT      |
//|                                      https://cindo.pages.dev     |
//+------------------------------------------------------------------+
#property copyright   "Mochamad Tabrani & Antigravity AI"
#property link        "https://cindo.pages.dev"
#property version     "4.00"
#property description "EA Pro: 100% Full Auto Directional Crossing & Reverse Martingale (Max Step 6 + Hedge Lock)"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| [1] Parameter Input                                              |
//+------------------------------------------------------------------+
input group "=== [PRO] 100% FULL AUTO ZERO-LEVEL REVERSE BOT ==="
input bool            InpEnableZeroBot     = true;      // 🤖 Aktifkan Robot 100% Otomatis?
input double          InpStartLot          = 0.01;      // Lot Dasar Awal (Step 1)
input double          InpLotMultiplier     = 2.0;       // Faktor Pengali Martingale (2.0x)
input int             InpMaxSteps          = 6;         // Batas Maksimal Step (Default: 6)
input double          InpPriceInterval     = 1.0;       // Jarak Level Angka Bulat ($1.00 = 10 Pips)
input bool            InpHedgeOnMaxStep    = true;      // 🔒 Kunci Akun (Hedge 1:1) jika Step 6 Kena SL?

input group "=== PENGATURAN TAMPILAN PANEL (WIDESCREEN ANTI TUMPUK) ==="
input int             InpWidth             = 430;   // Lebar Panel HUD (Pixel)
input int             InpX                 = 25;    // Posisi X dari kiri layar (Pixel)
input int             InpY                 = 35;    // Posisi Y dari atas layar (Pixel)

input group "=== PENGATURAN TRADING CEPAT (ONE-CLICK MANUAL) ==="
input double          InpDefaultLot        = 0.01;  // Ukuran Lot Default Manual
input double          InpLotStep           = 0.01;  // Nilai Tambah/Kurang Lot tombol [-] [+]

input group "=== AUTO TARGET KERANJANG (+PROFIT & -CUTLOSS) ==="
input double          InpBasketTargetMoney = 50.0;  // 🎯 Target Profit Uang ($) Tutup Otomatis (0 = Nonaktif)
input double          InpBasketMaxLossMoney= 100.0; // 🛑 Target Rugi Maksimal ($) Cutloss Otomatis (0 = Nonaktif)
input bool            InpEnableTrailingBE  = true;  // 🏃 Aktifkan Trailing Breakeven Pengunci Profit?
input int             InpTrailingStartPts  = 50;    // Jarak Profit (pts) untuk Mulai Aktifkan Trailing
input int             InpTrailingLockPts   = 15;    // Kunci Minimal Profit (pts) saat harga retrace

input group "=== PENGATURAN RADAR RISIKO & ZONA KERANJANG ==="
input int             InpWarningPts        = 500;   // Jarak Pts ke SO: Batas Status WASPADA
input int             InpDangerPts         = 200;   // Jarak Pts ke SO: Batas Status BAHAYA
input bool            InpShowSOLine        = true;  // Gambar Garis Level Stop Out (MC) di Chart
input bool            InpShowBELine        = true;  // Gambar Garis Titik Impas (Breakeven) di Chart
input bool            InpAutoCutEmergency  = false; // [AUTO CUT] Tutup Semua jika masuk Status BAHAYA

input group "=== PENGATURAN NOTIFIKASI / ALERT ==="
input bool            InpEnableAlert       = true;  // Popup Alert di layar MT5 saat TP/SL/Hedge kena?
input bool            InpEnablePush        = false; // Kirim Notifikasi ke HP (MetaQuotes ID)?
input bool            InpEnableEmail       = false; // Kirim Notifikasi via Email?

input group "=== PENGATURAN BULK CLOSE & FILTER ==="
input int             InpSlippage          = 30;    // Toleransi slippage (pts)
input long            InpMagicBot          = 888100;// Magic Number Khusus Robot Zero-Level
input long            InpMagicFilter       = 0;     // Magic Filter untuk HUD (0 = pantau semua)

//+------------------------------------------------------------------+
//| [2] Definisi Warna & Gaya Tampilan (Modern Glassmorphism)         |
//+------------------------------------------------------------------+
#define PREFIX          "RADAR_"
#define COLOR_PANEL_BG  C'18,20,26'      
#define COLOR_CARD_BG   C'26,30,39'      
#define COLOR_BORDER    C'45,52,65'      
#define COLOR_TEXT_DIM  C'150,158,175'   
#define COLOR_TEXT_VAL  C'235,240,250'   
#define COLOR_SAFE      C'0,230,130'     
#define COLOR_WARN      C'255,185,45'    
#define COLOR_DANGER    C'255,65,85'     
#define COLOR_ACCENT    C'60,165,255'    
#define FONT_UI         "Segoe UI"

enum ENUM_RISK_STATUS
{
   RISK_SAFE,
   RISK_WARNING,
   RISK_CRITICAL
};

//+------------------------------------------------------------------+
//| [3] Variabel Global                                              |
//+------------------------------------------------------------------+
double            g_point;
int               g_digits;
uint              g_lastUiTick      = 0;
bool              g_isClosing       = false;
bool              g_isMinimized     = false;
bool              g_trailingActive  = false;
ENUM_RISK_STATUS  g_currentStatus   = RISK_SAFE;
double            g_tradeLot        = 0.01;
CTrade            g_trade;

// Variabel Full Auto Zero-Level Bot
int               g_currentStep     = 1;
double            g_currentBotLot   = 0.01;
bool              g_isHedgeLocked   = false;
ulong             g_lastManagedDeal = 0;
double            g_lastPrice       = 0.0;

// Forward Declarations
void              UpdateRiskRadar();
void              CreateRadarHUD();
void              DeleteRadarObjects();
void              FastBulkClose(bool currentSymbolOnly);
void              UpdateButtonState(bool isClosing);
int               CountActivePositions(bool currentOnly);
void              ExecuteOneClickOrder(ENUM_POSITION_TYPE orderType);
void              ExecuteEmergencyHedge();
void              ExecuteReversePosition();
void              ExecuteCloseHalf();
void              CheckDirectionalCrossing();
void              OpenZeroBotOrder(ENUM_POSITION_TYPE type, double lot, double basePrice);
void              UpdateChartLines(double soPrice, double bePrice, bool hasExposure, bool isNotHedged, string beNote);
ENUM_ORDER_TYPE_FILLING GetOptimalFilling(string symbol);
double            NormalizeLotSize(double lot);
void              CreateBox(string name, int x, int y, int w, int h, color bg, color border);
void              CreateLbl(string name, int x, int y, string txt, color clr, int size = 8, bool bold = false, ENUM_ANCHOR_POINT anchor = ANCHOR_LEFT_UPPER);
void              CreateBtn(string name, int x, int y, int w, int h, string txt, color txtClr, color bgClr);
void              SetTxt(string name, string txt, color clr);

//+------------------------------------------------------------------+
//| [4] Inisialisasi & Lifecycle                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   g_point         = _Point;
   g_digits        = _Digits;
   g_tradeLot      = InpDefaultLot;
   g_currentBotLot = InpStartLot;
   g_currentStep   = 1;
   g_isHedgeLocked = false;
   g_lastPrice     = 0.0;

   g_trade.SetExpertMagicNumber(InpMagicBot);
   g_trade.SetDeviationInPoints(InpSlippage);
   g_trade.SetTypeFilling(GetOptimalFilling(_Symbol));

   DeleteRadarObjects();
   CreateRadarHUD();

   Print("=== RiskRadarHUD v4.00 Directional Crossing Bot Aktif ===");
   EventSetTimer(1);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   DeleteRadarObjects();
   ChartRedraw();
   Print("=== RiskRadarHUD Dihentikan ===");
}

void OnTick()
{
   // 1. Eksekutor Pemicu Awal Otomatis (Directional Crossing Level Bulat)
   if(InpEnableZeroBot && !g_isHedgeLocked && !g_isClosing)
   {
      CheckDirectionalCrossing();
   }

   // 2. Update Tampilan HUD setiap 120 ms
   uint now = GetTickCount();
   if(now - g_lastUiTick >= 120)
   {
      UpdateRiskRadar();
      g_lastUiTick = now;
   }
}

void OnTimer()
{
   UpdateRiskRadar();
   if(g_isClosing)
   {
      if(CountActivePositions(true) == 0)
      {
         g_isClosing = false;
         UpdateButtonState(false);
      }
   }
}

//+------------------------------------------------------------------+
//| [5] PEMICU AWAL OTOMATIS: DIRECTIONAL CROSSING DETECTOR          |
//+------------------------------------------------------------------+
void CheckDirectionalCrossing()
{
   // Pastikan tidak ada posisi bot yang sedang berjalan
   int botPositions = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicBot)
            botPositions++;
      }
   }

   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Inisialisasi harga awal pada tick pertama
   if(g_lastPrice <= 0.0)
   {
      g_lastPrice = currentBid;
      return;
   }

   // Jika sudah ada posisi yang aktif, simpan harga terakhir dan keluar
   if(botPositions > 0)
   {
      g_lastPrice = currentBid;
      return;
   }

   double step = InpPriceInterval;
   if(step <= 0) step = 1.0;

   // -------------------------------------------------------------
   // A. DETEKSI CROSSING NAIK (DARI BAWAH MENEMBUS KE ATAS LEVEL 0)
   // -------------------------------------------------------------
   double targetLevelUp = MathFloor(currentBid / step) * step;
   if(g_lastPrice < targetLevelUp && currentBid >= targetLevelUp)
   {
      Print(StringFormat("🚀 [DIRECTIONAL CROSS BUY] Harga melintas naik dari %.2f ke %.2f (Level: %.2f)!", g_lastPrice, currentBid, targetLevelUp));
      OpenZeroBotOrder(POSITION_TYPE_BUY, g_currentBotLot, targetLevelUp);
      g_lastPrice = currentBid;
      return;
   }

   // -------------------------------------------------------------
   // B. DETEKSI CROSSING TURUN (DARI ATAS MENEMBUS KE BAWAH LEVEL 0)
   // -------------------------------------------------------------
   double targetLevelDown = MathCeil(currentBid / step) * step;
   if(g_lastPrice > targetLevelDown && currentBid <= targetLevelDown)
   {
      Print(StringFormat("🔻 [DIRECTIONAL CROSS SELL] Harga melintas turun dari %.2f ke %.2f (Level: %.2f)!", g_lastPrice, currentBid, targetLevelDown));
      OpenZeroBotOrder(POSITION_TYPE_SELL, g_currentBotLot, targetLevelDown);
      g_lastPrice = currentBid;
      return;
   }

   g_lastPrice = currentBid;
}

//+------------------------------------------------------------------+
//| [6] TRADE TRANSACTION - MESIN STOP-AND-REVERSE MARTINGALE        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   ulong dealTicket = trans.deal;
   if(dealTicket == 0 || dealTicket == g_lastManagedDeal || !HistoryDealSelect(dealTicket)) return;

   long   dealEntry = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   long   dealType  = HistoryDealGetInteger(dealTicket, DEAL_TYPE);
   string sym       = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
   long   magic     = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
   long   dealReason= HistoryDealGetInteger(dealTicket, DEAL_REASON);

   if(sym != _Symbol || magic != InpMagicBot) return;

   if(dealEntry == DEAL_ENTRY_OUT)
   {
      g_lastManagedDeal = dealTicket;
      double profit     = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
      double closePrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);

      // Posisi asal sebelum ditutup:
      // Di MT5, deal penutup BUY bertipe DEAL_TYPE_SELL, dan sebaliknya.
      ENUM_POSITION_TYPE origPosType = (dealType == DEAL_TYPE_SELL) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;

      // -------------------------------------------------------------
      // KASUS 1: POSISI MENANG (TAKE PROFIT)
      // -------------------------------------------------------------
      if(dealReason == DEAL_REASON_TP || profit > 0)
      {
         string msg = StringFormat("🎯 [STEP %d TP HIT!] Profit: $%.2f. Reset ke Step 1 & Lanjut Tren...", g_currentStep, profit);
         Print(msg);
         if(InpEnableAlert) Alert(msg);

         // Reset siklus
         g_currentStep   = 1;
         g_currentBotLot = InpStartLot;

         if(InpEnableZeroBot && !g_isHedgeLocked)
         {
            // Buka posisi baru SEARAH tren pada harga TP tersebut
            OpenZeroBotOrder(origPosType, g_currentBotLot, closePrice);
         }
      }
      // -------------------------------------------------------------
      // KASUS 2: POSISI KALAH (STOP LOSS)
      // -------------------------------------------------------------
      else if(dealReason == DEAL_REASON_SL || profit < 0)
      {
         if(g_currentStep >= InpMaxSteps)
         {
            string msg = StringFormat("🚨 [MAKSIMAL STEP %d TERCAPAI!] Kerugian: $%.2f. Kunci Akun HEDGE 1:1...", g_currentStep, profit);
            Print(msg);
            if(InpEnableAlert) Alert(msg);
            if(InpEnablePush)  SendNotification(msg);

            g_isHedgeLocked = true;
            if(InpHedgeOnMaxStep)
            {
               ExecuteEmergencyHedge();
            }
            return;
         }

         g_currentStep++;
         g_currentBotLot = NormalizeLotSize(g_currentBotLot * InpLotMultiplier);

         string msg = StringFormat("🛑 [STEP %d SL HIT!] Eksekusi Balik Arah Martingale ke STEP %d (Lot: %.2f)...", g_currentStep - 1, g_currentStep, g_currentBotLot);
         Print(msg);
         if(InpEnableAlert) Alert(msg);

         if(InpEnableZeroBot && !g_isHedgeLocked)
         {
            // Buka posisi baru BERLAWANAN ARAH (Stop-and-Reverse)
            ENUM_POSITION_TYPE reverseType = (origPosType == POSITION_TYPE_BUY) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;
            OpenZeroBotOrder(reverseType, g_currentBotLot, closePrice);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| [7] EKSEKUTOR ORDER ZERO-LEVEL DENGAN TP/SL HARGA BULAT          |
//+------------------------------------------------------------------+
void OpenZeroBotOrder(ENUM_POSITION_TYPE type, double lot, double basePrice)
{
   lot = NormalizeLotSize(lot);
   double tp = 0.0;
   double sl = 0.0;

   if(type == POSITION_TYPE_BUY)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      tp = NormalizeDouble(basePrice + InpPriceInterval, g_digits);
      sl = NormalizeDouble(basePrice - InpPriceInterval, g_digits);
      g_trade.SetExpertMagicNumber(InpMagicBot);
      g_trade.Buy(lot, _Symbol, ask, sl, tp, StringFormat("ZeroBot BUY Stp%d", g_currentStep));
   }
   else
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      tp = NormalizeDouble(basePrice - InpPriceInterval, g_digits);
      sl = NormalizeDouble(basePrice + InpPriceInterval, g_digits);
      g_trade.SetExpertMagicNumber(InpMagicBot);
      g_trade.Sell(lot, _Symbol, bid, sl, tp, StringFormat("ZeroBot SELL Stp%d", g_currentStep));
   }
}

//+------------------------------------------------------------------+
//| [8] FITUR PENGAMAN & TOOLS LANJUTAN: HEDGE, REVERSE, BULK CLOSE   |
//+------------------------------------------------------------------+
void ExecuteEmergencyHedge()
{
   double buyLots = 0, sellLots = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol)
         {
            if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
               buyLots += PositionGetDouble(POSITION_VOLUME);
            else
               sellLots += PositionGetDouble(POSITION_VOLUME);
         }
      }
   }

   double netLots = buyLots - sellLots;
   if(MathAbs(netLots) < 0.00001)
   {
      Alert("Akun sudah terkunci 100% (Hedge 1:1)!");
      return;
   }

   double hedgeLot = NormalizeLotSize(MathAbs(netLots));
   if(hedgeLot <= 0) return;

   g_trade.SetExpertMagicNumber(0);
   if(netLots > 0)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(g_trade.Sell(hedgeLot, _Symbol, bid, 0, 0, "EMERGENCY HEDGE 1:1"))
         Alert("🔒 EMERGENCY HEDGE: Membuka SELL " + DoubleToString(hedgeLot, 2) + " Lot. Akun Terkunci Aman!");
   }
   else
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(g_trade.Buy(hedgeLot, _Symbol, ask, 0, 0, "EMERGENCY HEDGE 1:1"))
         Alert("🔒 EMERGENCY HEDGE: Membuka BUY " + DoubleToString(hedgeLot, 2) + " Lot. Akun Terkunci Aman!");
   }
}

void ExecuteReversePosition()
{
   double buyLots = 0, sellLots = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol)
         {
            if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
               buyLots += PositionGetDouble(POSITION_VOLUME);
            else
               sellLots += PositionGetDouble(POSITION_VOLUME);
         }
      }
   }

   if(buyLots == 0 && sellLots == 0) return;

   ENUM_POSITION_TYPE targetType = (buyLots >= sellLots) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;
   double targetLot = NormalizeLotSize(MathMax(buyLots, sellLots));

   FastBulkClose(true);

   g_trade.SetExpertMagicNumber(0);
   if(targetLot > 0)
   {
      if(targetType == POSITION_TYPE_BUY)
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         g_trade.Buy(targetLot, _Symbol, ask, 0, 0, "MANUAL REVERSE BUY");
      }
      else
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         g_trade.Sell(targetLot, _Symbol, bid, 0, 0, "MANUAL REVERSE SELL");
      }
      Print("🔄 REVERSE POSITION BERHASIL!");
   }
}

void ExecuteCloseHalf()
{
   int closed = 0;
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol)
         {
            double vol = PositionGetDouble(POSITION_VOLUME);
            double halfVol = NormalizeDouble(MathRound((vol * 0.5) / stepLot) * stepLot, 2);

            if(halfVol >= minLot && halfVol < vol)
            {
               if(g_trade.PositionClosePartial(t, halfVol))
                  closed++;
            }
         }
      }
   }
   if(closed > 0)
      Print("✂️ Berhasil menutup 50% volume dari ", closed, " posisi!");
}

void ExecuteOneClickOrder(ENUM_POSITION_TYPE orderType)
{
   double price = (orderType == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   g_trade.SetExpertMagicNumber(0);

   if(orderType == POSITION_TYPE_BUY)
      g_trade.Buy(g_tradeLot, _Symbol, price, 0, 0, "Radar Manual BUY");
   else
      g_trade.Sell(g_tradeLot, _Symbol, price, 0, 0, "Radar Manual SELL");
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

void FastBulkClose(bool currentSymbolOnly)
{
   ulong tickets[];
   int total = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t))
      {
         string sym = PositionGetString(POSITION_SYMBOL);
         if(currentSymbolOnly && sym != _Symbol) continue;

         ArrayResize(tickets, total + 1);
         tickets[total++] = t;
      }
   }

   if(total == 0) return;

   g_isClosing = true;
   UpdateButtonState(true);

   for(int i = 0; i < total; i++)
   {
      if(!PositionSelectByTicket(tickets[i])) continue;

      MqlTradeRequest request;
      MqlTradeResult  result;
      ZeroMemory(request);
      ZeroMemory(result);

      ENUM_POSITION_TYPE pType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      string sym               = PositionGetString(POSITION_SYMBOL);
      double vol               = PositionGetDouble(POSITION_VOLUME);

      request.action       = TRADE_ACTION_DEAL;
      request.position     = tickets[i];
      request.symbol       = sym;
      request.volume       = vol;
      request.deviation    = InpSlippage;
      request.type         = (pType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      request.price        = (pType == POSITION_TYPE_BUY) ? SymbolInfoDouble(sym, SYMBOL_BID) : SymbolInfoDouble(sym, SYMBOL_ASK);
      request.type_filling = GetOptimalFilling(sym);

      OrderSendAsync(request, result);
   }
}

//+------------------------------------------------------------------+
//| [9] Event Handler Klik Tombol UI                                 |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long& lparam, const double& dparam, const string& sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      if(sparam == PREFIX + "BTN_MINMAX")
      {
         g_isMinimized = !g_isMinimized;
         DeleteRadarObjects();
         CreateRadarHUD();
         ChartRedraw();
         return;
      }

      double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
      double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      if(stepLot <= 0) stepLot = 0.01;

      if(sparam == PREFIX + "BTN_LOT_MINUS")
      {
         g_tradeLot -= InpLotStep;
         if(g_tradeLot < minLot) g_tradeLot = minLot;
         g_tradeLot = NormalizeDouble(MathRound(g_tradeLot / stepLot) * stepLot, 2);
         SetTxt(PREFIX + "V_TradeLot", DoubleToString(g_tradeLot, 2) + " Lot", COLOR_TEXT_VAL);
         ChartRedraw();
      }
      else if(sparam == PREFIX + "BTN_LOT_PLUS")
      {
         g_tradeLot += InpLotStep;
         if(g_tradeLot > maxLot) g_tradeLot = maxLot;
         g_tradeLot = NormalizeDouble(MathRound(g_tradeLot / stepLot) * stepLot, 2);
         SetTxt(PREFIX + "V_TradeLot", DoubleToString(g_tradeLot, 2) + " Lot", COLOR_TEXT_VAL);
         ChartRedraw();
      }
      else if(sparam == PREFIX + "BTN_EXEC_BUY")
      {
         ExecuteOneClickOrder(POSITION_TYPE_BUY);
         ChartRedraw();
      }
      else if(sparam == PREFIX + "BTN_EXEC_SELL")
      {
         ExecuteOneClickOrder(POSITION_TYPE_SELL);
         ChartRedraw();
      }
      else if(sparam == PREFIX + "BTN_HEDGE")
      {
         ExecuteEmergencyHedge();
         ChartRedraw();
      }
      else if(sparam == PREFIX + "BTN_REVERSE")
      {
         ExecuteReversePosition();
         ChartRedraw();
      }
      else if(sparam == PREFIX + "BTN_CLOSE_HALF")
      {
         ExecuteCloseHalf();
         ChartRedraw();
      }
      else if(sparam == PREFIX + "BTN_CLOSE_CURR")
      {
         FastBulkClose(true);
         ChartRedraw();
      }
      else if(sparam == PREFIX + "BTN_CLOSE_ALL")
      {
         FastBulkClose(false);
         ChartRedraw();
      }
   }
}

//+------------------------------------------------------------------+
//| [10] Kalkulasi & Update Radar Risiko + Zona Impas Keranjang      |
//+------------------------------------------------------------------+
void UpdateRiskRadar()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double buyLots      = 0, sellLots      = 0;
   double buyValSum    = 0, sellValSum    = 0;
   double symbolPL     = 0;
   int    posCountCurr = 0;
   int    posCountAll  = PositionsTotal();

   for(int i = posCountAll - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol)
         {
            posCountCurr++;
            double vol   = PositionGetDouble(POSITION_VOLUME);
            double price = PositionGetDouble(POSITION_PRICE_OPEN);
            ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

            if(type == POSITION_TYPE_BUY)  { buyLots  += vol; buyValSum  += price * vol; }
            else if(type == POSITION_TYPE_SELL) { sellLots += vol; sellValSum += price * vol; }

            symbolPL += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         }
      }
   }

   // Auto Reset status Hedge jika posisi akun sudah dibersihkan/ditutup oleh operator
   if(posCountCurr == 0 && g_isHedgeLocked)
   {
      g_isHedgeLocked = false;
      g_currentStep   = 1;
      g_currentBotLot = InpStartLot;
      Print("🔄 SIKLUS DI-RESET: Operator telah menutup posisi. Robot kembali standby mencari crossing!");
   }

   double avgBuyPrice  = (buyLots  > 0) ? (buyValSum  / buyLots)  : 0;
   double avgSellPrice = (sellLots > 0) ? (sellValSum / sellLots) : 0;
   double netLots      = buyLots - sellLots;
   bool   hasExposure  = (buyLots > 0 || sellLots > 0);

   // Target Keranjang
   if(InpBasketTargetMoney > 0 && symbolPL >= InpBasketTargetMoney && !g_isClosing && posCountCurr > 0)
   {
      Print(StringFormat("🎯 TARGET PROFIT KERANJANG TERCAPAI ($%.2f)! Bulk Close...", symbolPL));
      FastBulkClose(true);
      return;
   }

   double maxLossLimit = -MathAbs(InpBasketMaxLossMoney);
   if(InpBasketMaxLossMoney > 0 && symbolPL <= maxLossLimit && !g_isClosing && posCountCurr > 0)
   {
      Print(StringFormat("🛑 MAX LOSS TERSENTUH ($%.2f)! Cutloss Darurat...", symbolPL));
      FastBulkClose(true);
      return;
   }

   // Analisis Zona Breakeven
   double bePrice      = 0;
   string netBiasStr   = "NETRAL (0.00 Lot)";
   string posZoneStr   = "-";
   string negZoneStr   = "-";
   string distZoneStr  = "-";
   color  distZoneClr  = COLOR_TEXT_DIM;
   string beLabelTxt   = "";
   double diffPts      = 0;

   if(hasExposure)
   {
      if(MathAbs(netLots) > 0.00001)
      {
         if(netLots > 0)
         {
            bePrice    = (buyValSum - sellValSum) / netLots;
            netBiasStr = StringFormat("+%.2f Lot BUY (Net Long)", netLots);
            posZoneStr = StringFormat("> %s (Naik = Untung)", DoubleToString(bePrice, g_digits));
            negZoneStr = StringFormat("< %s (Turun = Rugi)", DoubleToString(bePrice, g_digits));
            beLabelTxt = " (▲ Untung, ▼ Rugi)";

            diffPts = (bid - bePrice) / g_point;
            if(diffPts >= 0)
            {
               distZoneStr = StringFormat("✅ Zona Untung (+%d pts)", (int)MathRound(diffPts));
               distZoneClr = COLOR_SAFE;
            }
            else
            {
               distZoneStr = StringFormat("⏳ Butuh +%d pts ke Impas", (int)MathRound(-diffPts));
               distZoneClr = COLOR_WARN;
            }
         }
         else
         {
            bePrice    = (sellValSum - buyValSum) / MathAbs(netLots);
            netBiasStr = StringFormat("%.2f Lot SELL (Net Short)", netLots);
            posZoneStr = StringFormat("< %s (Turun = Untung)", DoubleToString(bePrice, g_digits));
            negZoneStr = StringFormat("> %s (Naik = Rugi)", DoubleToString(bePrice, g_digits));
            beLabelTxt = " (▼ Untung, ▲ Rugi)";

            diffPts = (bePrice - ask) / g_point;
            if(diffPts >= 0)
            {
               distZoneStr = StringFormat("✅ Zona Untung (+%d pts)", (int)MathRound(diffPts));
               distZoneClr = COLOR_SAFE;
            }
            else
            {
               distZoneStr = StringFormat("⏳ Butuh +%d pts ke Impas", (int)MathRound(-diffPts));
               distZoneClr = COLOR_WARN;
            }
         }

         if(InpEnableTrailingBE && posCountCurr > 0)
         {
            if(!g_trailingActive && diffPts >= InpTrailingStartPts)
               g_trailingActive = true;
            else if(g_trailingActive && diffPts <= InpTrailingLockPts && !g_isClosing)
            {
               FastBulkClose(true);
               g_trailingActive = false;
               return;
            }
         }
      }
      else
      {
         netBiasStr  = "TERKUNCI (Hedge 100%)";
         posZoneStr  = "P/L Terkunci Tetap";
         negZoneStr  = "Kebal Fluktuasi Pasar";
         distZoneStr = "🔒 Posisi Hedging Imbang";
         distZoneClr = COLOR_ACCENT;
         g_trailingActive = false;
      }
   }

   // Nilai Poin Stop Out
   double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ptVal1Lot  = (tickSize > 0) ? tickValue * (g_point / tickSize) : g_point;
   double totalPtVal = MathAbs(netLots) * ptVal1Lot;
   double ptsFloating = (totalPtVal > 0) ? (symbolPL / totalPtVal) : 0;

   double margin       = AccountInfoDouble(ACCOUNT_MARGIN);
   double marginLevel  = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   double soLevel      = AccountInfoDouble(ACCOUNT_MARGIN_SO_SO);
   long   soMode       = AccountInfoInteger(ACCOUNT_MARGIN_SO_MODE);

   double equitySO     = (soMode == ACCOUNT_STOPOUT_MODE_PERCENT) ? (soLevel * margin / 100.0) : soLevel;
   double eqToSO       = equity - equitySO;
   double ptsToSO      = 0;
   double soPrice      = 0;
   string ptsToSOStr   = "-";
   string soPriceStr   = "-";

   if(hasExposure && margin > 0)
   {
      if(totalPtVal > 0)
      {
         ptsToSO = eqToSO / totalPtVal;
         if(ptsToSO < 0) ptsToSO = 0;
         ptsToSOStr = StringFormat("%d pts (%d pips)", (int)MathRound(ptsToSO), (int)MathRound(ptsToSO / 10.0));
         soPrice = (netLots > 0) ? (bid - ptsToSO * g_point) : (ask + ptsToSO * g_point);
         soPriceStr = DoubleToString(soPrice, g_digits);
      }
      else
      {
         ptsToSOStr = "TERKUNCI (Hedge 100%)";
         soPriceStr = "AMAN (Terkunci)";
      }
   }

   color statusColor = COLOR_SAFE;
   string statusText = "● STATUS: AMAN";
   g_currentStatus   = RISK_SAFE;

   if(hasExposure && totalPtVal > 0)
   {
      if(ptsToSO <= InpDangerPts || (marginLevel > 0 && marginLevel <= 150.0))
      {
         statusColor     = COLOR_DANGER;
         statusText      = "🚨 KRITIS / BAHAYA!";
         g_currentStatus = RISK_CRITICAL;
         if(InpAutoCutEmergency && !g_isClosing) FastBulkClose(true);
      }
      else if(ptsToSO <= InpWarningPts || (marginLevel > 0 && marginLevel <= 300.0))
      {
         statusColor     = COLOR_WARN;
         statusText      = "⚠️ WASPADA!";
         g_currentStatus = RISK_WARNING;
      }
   }

   // Update Status Banner Zero-Level Bot
   string zeroBotBanner = "";
   if(!InpEnableZeroBot)
      zeroBotBanner = "🤖 ZERO-BOT: NONAKTIF (MANUAL)";
   else if(g_isHedgeLocked)
      zeroBotBanner = "🔒 ZERO-BOT: HEDGE LOCKED (STEP 6 HIT)";
   else if(posCountCurr == 0)
      zeroBotBanner = "🤖 ZERO-BOT: STANDBY MENUNGGU CROSSING";
   else
      zeroBotBanner = StringFormat("🤖 ZERO-BOT: STEP %d/%d (Lot: %.2f)", g_currentStep, InpMaxSteps, g_currentBotLot);

   SetTxt(PREFIX + "L_ZeroInfo", zeroBotBanner, g_isHedgeLocked ? COLOR_WARN : COLOR_ACCENT);
   SetTxt(PREFIX + "Badge", statusText, statusColor);

   string plStr = StringFormat("$%.2f (%+d pts)", symbolPL, (int)MathRound(ptsFloating));
   color  plClr = (symbolPL > 0.001) ? COLOR_SAFE : (symbolPL < -0.001 ? COLOR_DANGER : COLOR_TEXT_DIM);

   if(g_isMinimized)
   {
      SetTxt(PREFIX + "MiniPL", plStr, plClr);
      ChartRedraw();
      return;
   }

   SetTxt(PREFIX + "V_Bal",  StringFormat("$%.2f", balance), COLOR_TEXT_VAL);
   SetTxt(PREFIX + "V_Eq",   StringFormat("$%.2f", equity),  COLOR_TEXT_VAL);
   SetTxt(PREFIX + "V_PL",   plStr, plClr);

   string bExp = (buyLots > 0) ? StringFormat("%.2f Lot @ %s ▲", buyLots, DoubleToString(avgBuyPrice, g_digits - 1)) : "0.00 Lot";
   string sExp = (sellLots > 0)? StringFormat("%.2f Lot @ %s ▼", sellLots, DoubleToString(avgSellPrice, g_digits - 1)) : "0.00 Lot";
   SetTxt(PREFIX + "V_BuyExp",   bExp, (buyLots > 0 ? COLOR_SAFE : COLOR_TEXT_DIM));
   SetTxt(PREFIX + "V_SellExp",  sExp, (sellLots > 0 ? COLOR_DANGER : COLOR_TEXT_DIM));
   SetTxt(PREFIX + "V_NetBias",  netBiasStr, (netLots > 0 ? COLOR_SAFE : (netLots < 0 ? COLOR_DANGER : COLOR_ACCENT)));
   SetTxt(PREFIX + "V_BEPrice",  (bePrice > 0 ? DoubleToString(bePrice, g_digits) : "-"), COLOR_ACCENT);
   SetTxt(PREFIX + "V_PosZone",  posZoneStr, COLOR_SAFE);
   SetTxt(PREFIX + "V_NegZone",  negZoneStr, COLOR_DANGER);
   SetTxt(PREFIX + "V_DistZone", distZoneStr, distZoneClr);

   string mlStr = (margin > 0) ? StringFormat("%.1f%% (SO: %.0f%%)", marginLevel, soLevel) : "-";
   SetTxt(PREFIX + "V_ML",      mlStr, statusColor);
   SetTxt(PREFIX + "V_EqSO",    (margin > 0 ? StringFormat("$%.2f", eqToSO) : "-"), statusColor);
   SetTxt(PREFIX + "V_PtsSO",   ptsToSOStr, statusColor);
   SetTxt(PREFIX + "V_PriceSO", soPriceStr, statusColor);

   SetTxt(PREFIX + "BTN_EXEC_BUY",  StringFormat("▲ BUY  %s", DoubleToString(ask, g_digits)), clrWhite);
   SetTxt(PREFIX + "BTN_EXEC_SELL", StringFormat("▼ SELL  %s", DoubleToString(bid, g_digits)), clrWhite);
   SetTxt(PREFIX + "BTN_CLOSE_CURR", StringFormat("⚡ BULK CLOSE %s (%d Posisi)", _Symbol, posCountCurr), clrWhite);
   SetTxt(PREFIX + "BTN_CLOSE_ALL",  StringFormat("💀 PANIC CLOSE ALL AKUN (%d Posisi)", posCountAll), clrWhite);

   UpdateChartLines(soPrice, bePrice, hasExposure, totalPtVal > 0, beLabelTxt);
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| [11] Garis Visual Chart & HUD Designer                           |
//+------------------------------------------------------------------+
void UpdateChartLines(double soPrice, double bePrice, bool hasExposure, bool isNotHedged, string beNote)
{
   string soLineName = PREFIX + "LINE_SO";
   string beLineName = PREFIX + "LINE_BE";

   if(InpShowSOLine && hasExposure && isNotHedged && soPrice > 0)
   {
      if(ObjectFind(0, soLineName) < 0)
         ObjectCreate(0, soLineName, OBJ_HLINE, 0, 0, soPrice);
      else
         ObjectSetDouble(0, soLineName, OBJPROP_PRICE, soPrice);

      ObjectSetInteger(0, soLineName, OBJPROP_COLOR, COLOR_DANGER);
      ObjectSetInteger(0, soLineName, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, soLineName, OBJPROP_WIDTH, 2);
      ObjectSetString (0, soLineName, OBJPROP_TEXT,  " 🚨 LEVEL STOP OUT / MC (" + DoubleToString(soPrice, g_digits) + ")");
   }
   else
      ObjectDelete(0, soLineName);

   if(InpShowBELine && hasExposure && bePrice > 0)
   {
      if(ObjectFind(0, beLineName) < 0)
         ObjectCreate(0, beLineName, OBJ_HLINE, 0, 0, bePrice);
      else
         ObjectSetDouble(0, beLineName, OBJPROP_PRICE, bePrice);

      ObjectSetInteger(0, beLineName, OBJPROP_COLOR, COLOR_ACCENT);
      ObjectSetInteger(0, beLineName, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, beLineName, OBJPROP_WIDTH, 1);
      ObjectSetString (0, beLineName, OBJPROP_TEXT,  " 🎯 TITIK IMPAS: " + DoubleToString(bePrice, g_digits) + beNote);
   }
   else
      ObjectDelete(0, beLineName);
}

void CreateRadarHUD()
{
   int x = InpX;
   int y = InpY;
   int w = InpWidth;

   if(g_isMinimized)
   {
      CreateBox(PREFIX + "MainBg", x, y, w, 44, COLOR_PANEL_BG, COLOR_BORDER);
      CreateLbl(PREFIX + "Title", x + 12, y + 13, "🛡️ RADAR ZERO", COLOR_ACCENT, 9, true);
      CreateLbl(PREFIX + "MiniPL", x + 120, y + 13, "$0.00", COLOR_SAFE, 9, true);
      CreateLbl(PREFIX + "Badge", x + w - 45, y + 13, "● AMAN", COLOR_SAFE, 8, true, ANCHOR_RIGHT_UPPER);
      CreateBtn(PREFIX + "BTN_MINMAX", x + w - 35, y + 8, 26, 26, "▢", clrWhite, C'45,52,65');
      return;
   }

   int h = 675;
   CreateBox(PREFIX + "MainBg", x, y, w, h, COLOR_PANEL_BG, COLOR_BORDER);

   // Header Panel
   CreateBox(PREFIX + "HeaderBg", x + 5, y + 5, w - 10, 36, COLOR_CARD_BG, COLOR_BORDER);
   CreateLbl(PREFIX + "Title", x + 15, y + 13, "🛡️ ZERO-LEVEL RADAR PRO", COLOR_ACCENT, 10, true);
   CreateLbl(PREFIX + "Badge", x + w - 50, y + 13, "● STATUS: AMAN", COLOR_SAFE, 9, true, ANCHOR_RIGHT_UPPER);
   CreateBtn(PREFIX + "BTN_MINMAX", x + w - 38, y + 10, 26, 26, "—", clrWhite, C'45,52,65');

   int curY = y + 46;

   // STATUS ZERO-BOT BANNER
   CreateBox(PREFIX + "SubHead", x + 5, curY, w - 10, 20, C'20,25,32', COLOR_BORDER);
   CreateLbl(PREFIX + "L_ZeroInfo", x + 15, curY + 4, "🤖 ZERO-BOT: STANDBY MENUNGGU CROSSING", COLOR_ACCENT, 8, true);

   curY += 25;

   // CARD TRADING CEPAT MANUAL
   CreateBox(PREFIX + "CardTrade", x + 5, curY, w - 10, 115, COLOR_CARD_BG, COLOR_BORDER);
   CreateLbl(PREFIX + "L_LotLabel", x + 15, curY + 8, "Volume Lot Manual:", COLOR_TEXT_DIM, 8);
   CreateBtn(PREFIX + "BTN_LOT_MINUS", x + 145, curY + 5, 34, 20, "-", COLOR_TEXT_VAL, C'45,50,65');
   CreateLbl(PREFIX + "V_TradeLot",  x + 230, curY + 7, DoubleToString(g_tradeLot, 2) + " Lot", COLOR_ACCENT, 9, true, ANCHOR_CENTER);
   CreateBtn(PREFIX + "BTN_LOT_PLUS",  x + 280, curY + 5, 34, 20, "+", COLOR_TEXT_VAL, C'45,50,65');

   int btnW = (w - 20) / 2;
   CreateBtn(PREFIX + "BTN_EXEC_BUY",  x + 7,        curY + 32, btnW, 36, "▲ BUY",  clrWhite, C'16,140,75');
   CreateBtn(PREFIX + "BTN_EXEC_SELL", x + 11 + btnW, curY + 32, btnW, 36, "▼ SELL", clrWhite, C'175,35,45');

   int toolW = (w - 24) / 3;
   CreateBtn(PREFIX + "BTN_HEDGE",      x + 7,             curY + 74, toolW, 32, "🔒 HEDGE 1:1", clrWhite, C'20,95,155');
   CreateBtn(PREFIX + "BTN_REVERSE",    x + 9 + toolW,     curY + 74, toolW, 32, "🔄 REVERSE",   clrWhite, C'180,105,15');
   CreateBtn(PREFIX + "BTN_CLOSE_HALF", x + 11 + toolW * 2, curY + 74, toolW, 32, "✂️ CLOSE 50%", clrWhite, C'95,45,135');

   curY += 123;

   // CARD 1: KEUANGAN & TARGET KERANJANG
   CreateBox(PREFIX + "Card1", x + 5, curY, w - 10, 85, COLOR_CARD_BG, COLOR_BORDER);
   CreateLbl(PREFIX + "L_Bal",  x + 15, curY + 8,  "Saldo Akun:",  COLOR_TEXT_DIM, 8);
   CreateLbl(PREFIX + "V_Bal",  x + 115, curY + 8, "$0.00",        COLOR_TEXT_VAL, 8, true);
   CreateLbl(PREFIX + "L_Eq",   x + 220, curY + 8, "Equity:",      COLOR_TEXT_DIM, 8);
   CreateLbl(PREFIX + "V_Eq",   x + w - 15, curY + 8, "$0.00",     COLOR_TEXT_VAL, 8, true, ANCHOR_RIGHT_UPPER);

   CreateLbl(PREFIX + "L_PL",   x + 15, curY + 32, "Simbol Floating P/L:", COLOR_TEXT_DIM, 8);
   CreateLbl(PREFIX + "V_PL",   x + w - 15, curY + 32, "$0.00 (0 pts)", COLOR_TEXT_VAL, 9, true, ANCHOR_RIGHT_UPPER);

   string targetTxt  = (InpBasketTargetMoney > 0)  ? StringFormat("🎯 Target (+): +$%.2f", InpBasketTargetMoney)  : "🎯 Target: OFF";
   string cutlossTxt = (InpBasketMaxLossMoney > 0) ? StringFormat("🛑 Cutloss (-): -$%.2f", InpBasketMaxLossMoney) : "🛑 Cutloss: OFF";
   CreateLbl(PREFIX + "L_Target",  x + 15, curY + 56, targetTxt,  COLOR_SAFE,   8, true);
   CreateLbl(PREFIX + "L_Cutloss", x + 220, curY + 56, cutlossTxt, COLOR_DANGER, 8, true);

   curY += 92;

   // CARD 2: ANALISIS EXPOSURE & ZONA IMPAS
   CreateBox(PREFIX + "Card2", x + 5, curY, w - 10, 130, COLOR_CARD_BG, COLOR_BORDER);
   CreateLbl(PREFIX + "L_ExpTitle", x + 15, curY + 6, "ANALISIS KERANJANG & ZONA IMPAS", COLOR_ACCENT, 8, true);
   CreateLbl(PREFIX + "L_BuyExp",   x + 15, curY + 25, "Buy Exposure:",  COLOR_TEXT_DIM, 8);
   CreateLbl(PREFIX + "V_BuyExp",   x + w - 15, curY + 25, "0.00 Lot",   COLOR_TEXT_VAL, 8, true, ANCHOR_RIGHT_UPPER);
   CreateLbl(PREFIX + "L_SellExp",  x + 15, curY + 44, "Sell Exposure:", COLOR_TEXT_DIM, 8);
   CreateLbl(PREFIX + "V_SellExp",  x + w - 15, curY + 44, "0.00 Lot",   COLOR_TEXT_VAL, 8, true, ANCHOR_RIGHT_UPPER);
   CreateLbl(PREFIX + "L_NetBias",  x + 15, curY + 63, "Net Bias:",      COLOR_TEXT_DIM, 8);
   CreateLbl(PREFIX + "V_NetBias",  x + w - 15, curY + 63, "-",          COLOR_TEXT_VAL, 8, true, ANCHOR_RIGHT_UPPER);
   CreateLbl(PREFIX + "L_PosZone",  x + 15, curY + 82, "🟢 Zona Untung (+):", COLOR_TEXT_DIM, 8);
   CreateLbl(PREFIX + "V_PosZone",  x + w - 15, curY + 82, "-",          COLOR_SAFE,     8, true, ANCHOR_RIGHT_UPPER);
   CreateLbl(PREFIX + "L_NegZone",  x + 15, curY + 99, "🔴 Zona Rugi   (-):", COLOR_TEXT_DIM, 8);
   CreateLbl(PREFIX + "V_NegZone",  x + w - 15, curY + 99, "-",          COLOR_DANGER,   8, true, ANCHOR_RIGHT_UPPER);
   CreateLbl(PREFIX + "L_DistZone", x + 15, curY + 115, "Status Jarak Impas:", COLOR_TEXT_DIM, 8);
   CreateLbl(PREFIX + "V_DistZone", x + w - 15, curY + 115, "-",         COLOR_TEXT_VAL, 8, true, ANCHOR_RIGHT_UPPER);

   curY += 137;

   // CARD 3: DETEKTOR MARGIN CALL / STOP OUT
   CreateBox(PREFIX + "Card3", x + 5, curY, w - 10, 105, COLOR_CARD_BG, COLOR_BORDER);
   CreateLbl(PREFIX + "L_RadarTitle", x + 15, curY + 6, "DETEKTOR MARGIN CALL / STOP OUT", COLOR_WARN, 8, true);
   CreateLbl(PREFIX + "L_ML",     x + 15, curY + 26, "Margin Level:",  COLOR_TEXT_DIM, 8);
   CreateLbl(PREFIX + "V_ML",     x + w - 15, curY + 26, "0.00%",       COLOR_TEXT_VAL, 8, true, ANCHOR_RIGHT_UPPER);
   CreateLbl(PREFIX + "L_EqSO",   x + 15, curY + 45, "Sisa Modal SO:",  COLOR_TEXT_DIM, 8);
   CreateLbl(PREFIX + "V_EqSO",   x + w - 15, curY + 45, "$0.00",       COLOR_TEXT_VAL, 8, true, ANCHOR_RIGHT_UPPER);
   CreateLbl(PREFIX + "L_PtsSO",  x + 15, curY + 64, "Jarak Pts ke SO:", COLOR_TEXT_DIM, 8);
   CreateLbl(PREFIX + "V_PtsSO",  x + w - 15, curY + 64, "0 pts",       COLOR_TEXT_VAL, 8, true, ANCHOR_RIGHT_UPPER);
   CreateLbl(PREFIX + "L_PriceSO",x + 15, curY + 83, "Level Harga SO:", COLOR_TEXT_DIM, 8);
   CreateLbl(PREFIX + "V_PriceSO",x + w - 15, curY + 83, "-",           COLOR_TEXT_VAL, 8, true, ANCHOR_RIGHT_UPPER);

   curY += 112;

   // TOMBOL BULK CLOSE
   CreateBtn(PREFIX + "BTN_CLOSE_CURR", x + 5, curY, w - 10, 36, "⚡ BULK CLOSE SYMBOL (0 Posisi)", clrWhite, COLOR_DANGER);
   curY += 41;
   CreateBtn(PREFIX + "BTN_CLOSE_ALL",  x + 5, curY, w - 10, 24, "💀 PANIC CLOSE ALL AKUN (0 Posisi)", COLOR_TEXT_DIM, C'38,42,54');
}

void UpdateButtonState(bool isClosing)
{
   if(isClosing)
   {
      ObjectSetString(0, PREFIX + "BTN_CLOSE_CURR", OBJPROP_TEXT, "⏳ MEMPROSES BULK CLOSE...");
      ObjectSetInteger(0, PREFIX + "BTN_CLOSE_CURR", OBJPROP_BGCOLOR, C'160,110,20');
   }
   else
      ObjectSetInteger(0, PREFIX + "BTN_CLOSE_CURR", OBJPROP_BGCOLOR, COLOR_DANGER);
}

int CountActivePositions(bool currentOnly)
{
   if(!currentOnly) return PositionsTotal();
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t))
      {
         long magic = PositionGetInteger(POSITION_MAGIC);
         if(InpMagicFilter != 0 && magic != InpMagicFilter) continue;
         if(PositionGetString(POSITION_SYMBOL) == _Symbol)
            count++;
      }
   }
   return count;
}

void DeleteRadarObjects()
{
   for(int i = ObjectsTotal(0) - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i);
      if(StringFind(name, PREFIX) == 0)
         ObjectDelete(0, name);
   }
}

void CreateBox(string name, int x, int y, int w, int h, color bg, color border)
{
   ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER,      CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE,   x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE,   y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE,       w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE,       h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR,     bg);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR,border);
   ObjectSetInteger(0, name, OBJPROP_BACK,        false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE,  false);
}

void CreateLbl(string name, int x, int y, string txt, color clr, int size = 8, bool bold = false, ENUM_ANCHOR_POINT anchor = ANCHOR_LEFT_UPPER)
{
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER,    CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT,       txt);
   ObjectSetInteger(0, name, OBJPROP_COLOR,     clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,  size);
   ObjectSetString(0, name, OBJPROP_FONT,       bold ? "Segoe UI Semibold" : FONT_UI);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR,    anchor);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE,false);
}

void CreateBtn(string name, int x, int y, int w, int h, string txt, color txtClr, color bgClr)
{
   ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER,       CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE,    x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE,    y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE,        w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE,        h);
   ObjectSetString (0, name, OBJPROP_TEXT,         txt);
   ObjectSetInteger(0, name, OBJPROP_COLOR,        txtClr);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR,      bgClr);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, COLOR_BORDER);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,     8);
   ObjectSetString (0, name, OBJPROP_FONT,         "Segoe UI Semibold");
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE,   false);
}

void SetTxt(string name, string txt, color clr)
{
   ObjectSetString (0, name, OBJPROP_TEXT,  txt);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}
//+------------------------------------------------------------------+
