//+------------------------------------------------------------------+
//|                          Grafik_Tabranij_Scalper_XAUUSD.mq5       |
//|                    Master MQL5 Gold Specialist - Standalone       |
//|            Genesis Riwayat Angka Faktual Informasi Keuangan       |
//+------------------------------------------------------------------+
#property copyright "Surgas & Master MQL5 Gold Specialist"
#property link      "https://github.com/surgas/tabranij"
#property version   "3.20"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| STRUKTUR DATA ANATOMI GRAFIK TABRANIJ (EMBEDDED)                  |
//+------------------------------------------------------------------+
struct Tabranij
{
   datetime Waktu;        // Waktu Bar (Historis, Live, atau Masa Depan)
   double   T;            // Tinggi (High)
   double   A;            // Atas = T - max(Awal, Inti) (Panjang Jarum/Penolakan Atas)
   double   B;            // Bawah = min(Awal, Inti) - R (Panjang Jarum/Penolakan Bawah)
   double   R;            // Rendah (Low)
   double   Awal;         // Awal (Open)
   double   N;            // Neto = |Inti - Awal| (Panjang Bersih Badan)
   double   I;            // Inti (Close / Live Price)
   double   J;            // Julat = Tinggi - Rendah (A + N + B)
   double   AtapBadan;    // max(Awal, Inti) -> Koordinat harga atap badan
   double   LantaiBadan;  // min(Awal, Inti) -> Koordinat harga lantai badan
   double   EkorAtas;     // Alias untuk A
   double   EkorBawah;    // Alias untuk B
   bool     IsNaik;
   double   VektorNeto;
   double   EfisiensiNeto;       // N / J (Neto %)
   double   RasioPenolakanAtas;  // A / J (Rasio Atas %)
   double   RasioPenolakanBawah; // B / J (Rasio Bawah %)
};

//+------------------------------------------------------------------+
//| STRUKTUR DATA EXPOSURE & STATISTIK POSISI KERANJANG              |
//+------------------------------------------------------------------+
struct BasketExposure
{
   int      total_count;
   int      buy_count;
   int      sell_count;
   int      pending_count;
   double   buy_lots;
   double   sell_lots;
   double   net_lots;
   double   buy_profit;
   double   sell_profit;
   double   total_profit;
   double   lowest_buy_price;
   double   highest_sell_price;
   double   last_buy_price;
   double   last_sell_price;
   datetime last_buy_time;
   datetime last_sell_time;
};

Tabranij HitungTabranij(string symbol, ENUM_TIMEFRAMES timeframe, int shift)
{
   Tabranij tab;
   ZeroMemory(tab);
   MqlRates rates[];
   ArraySetAsSeries(rates, true);

   if(CopyRates(symbol, timeframe, shift, 1, rates) < 1) return tab;

   tab.Waktu = rates[0].time;
   tab.T     = rates[0].high;
   tab.R     = rates[0].low;
   tab.Awal  = rates[0].open;
   tab.I     = rates[0].close;

   tab.AtapBadan   = MathMax(tab.Awal, tab.I);
   tab.LantaiBadan = MathMin(tab.Awal, tab.I);
   tab.A           = tab.T - tab.AtapBadan;   // A (Atas) = Penolakan Atas
   tab.B           = tab.LantaiBadan - tab.R; // B (Bawah) = Penolakan Bawah
   tab.EkorAtas    = tab.A;
   tab.EkorBawah   = tab.B;

   tab.N = MathAbs(tab.I - tab.Awal);
   tab.J = tab.T - tab.R; // A + N + B == J

   tab.VektorNeto = tab.I - tab.Awal;
   tab.IsNaik     = (tab.I >= tab.Awal);

   if(tab.J > 0)
   {
      tab.EfisiensiNeto       = tab.N / tab.J;
      tab.RasioPenolakanAtas  = tab.A / tab.J;
      tab.RasioPenolakanBawah = tab.B / tab.J;
   }
   return tab;
}

//+------------------------------------------------------------------+
//| Cari Nilai Tinggi (T) Tertinggi & Rendah (R) Terendah N Bar Lalu |
//+------------------------------------------------------------------+
bool GetExtremeTR(string symbol, ENUM_TIMEFRAMES timeframe, int start_shift, int count,
                  double &out_highest_T, double &out_lowest_R)
{
   out_highest_T = 0.0;
   out_lowest_R  = 0.0;
   if(count <= 0) return false;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);

   int copied = CopyRates(symbol, timeframe, start_shift, count, rates);
   if(copied < 1) return false;

   out_highest_T = rates[0].high;
   out_lowest_R  = rates[0].low;

   for(int i = 1; i < copied; i++)
   {
      if(rates[i].high > out_highest_T) out_highest_T = rates[i].high;
      if(rates[i].low  < out_lowest_R)  out_lowest_R  = rates[i].low;
   }
   return true;
}

CTrade trade;

// 1. Pilihan 6 Mode Sinyal Anatomi Tabranij
enum ENUM_ENTRY_MODE
{
   MODE_FOLLOW_TREND,    // 1. Follow Trend: Momentum Neto Searah Candle
   MODE_COUNTER_TREND,   // 2. Counter Trend: Lawan Arah Neto Candle
   MODE_REJECTION_EKOR,  // 3. Mode Ekor: Berdasarkan Ekor Atas (eka) & Ekor Bawah (ekb)
   MODE_BREAKOUT,        // 4. Breakout: Inti Tembus Tinggi (T) / Rendah (R) Sebelumnya
   MODE_REVERSAL,        // 5. Reversal: Sweep T/R (False Break) & Engulfing Neto
   MODE_SMART_HYBRID     // 6. Smart Hybrid: Otomatis Breakout, Reversal, Ekor & Neto (100% Aktif)
};

// 2. Pilihan Logika Arah Ekor Atas (eka) & Ekor Bawah (ekb)
enum ENUM_EKOR_DIRECTION
{
   EKOR_A_BUY_B_SELL,     // Atas (A) = BUY, Bawah (B) = SELL (Kejar Penolakan)
   EKOR_B_BUY_A_SELL,     // Bawah (B) = BUY, Atas (A) = SELL (Pantulan Penolakan)
   EKOR_EKA_BUY_EKB_SELL = EKOR_A_BUY_B_SELL, // Alias kompatibilitas
   EKOR_EKB_BUY_EKA_SELL = EKOR_B_BUY_A_SELL  // Alias kompatibilitas
};

// 3. Pilihan Mode Eksekusi Order (Market + Pending Limit & Stop Masa Depan)
enum ENUM_EXEC_ORDER_TYPE
{
   EXEC_MARKET_ONLY,         // 1. Hanya Market Order (Eksekusi Langsung)
   EXEC_MARKET_AND_LIMIT,    // 2. Market Order + Pending LIMIT di Kotak Proyeksi (+1, +2, +3)
   EXEC_MARKET_AND_STOP,     // 3. Market Order + Pending STOP di Kotak Proyeksi (+1, +2, +3)
   EXEC_MARKET_LIMIT_STOP,   // 4. Lengkap: Market Order + Pending LIMIT & STOP Masa Depan
   EXEC_PENDING_LIMIT_ONLY,  // 5. Hanya Pending LIMIT di Kotak Proyeksi Masa Depan
   EXEC_PENDING_STOP_ONLY,   // 6. Hanya Pending STOP di Kotak Proyeksi Masa Depan
   EXEC_PENDING_BOTH_ONLY    // 7. Hanya Pending LIMIT + STOP Masa Depan (Tanpa Market Order)
};

// 4. Pilihan Mode Kompas Multi-Timeframe (MTF)
enum ENUM_MTF_MODE
{
   MTF_OFF,                  // Non-Aktif (Bebas Entry Tanpa Ditahan TF Besar)
   MTF_LIVE_BAR0,            // Live Bar 0 HTF (Searah Neto Candle TF Besar Saat Ini)
   MTF_CLOSED_BAR1,          // Closed Bar 1 HTF (Searah Candle TF Besar yang Sudah Tutup)
   MTF_BREAKOUT_OR_REVERSAL  // Pintar: Ikuti Breakout / Reversal Ekor pada TF Besar
};

// 5. Pilihan Mode Arah Keranjang (Pilar 2: Anti-Kunci Buy vs Sell)
enum ENUM_BASKET_DIRECTION
{
   BASKET_MIXED_ANTI_LOCK,   // Gabungan 2 Arah + Otomatis Anti-Kunci (Cegah Lot Buy == Lot Sell)
   BASKET_ONE_WAY,           // Kunci 1 Arah Saja Sampai Keranjang Selesai TP/SL
   BASKET_SEPARATE_BUY_SELL  // Pisah Keranjang BUY & SELL Sendiri-Sendiri (Panen 2 Arah)
};

// 6. Pilihan Mode Jarak Antar Order / Pip Step (Pilar 2: Layering Filter)
enum ENUM_STEP_MODE
{
   STEP_FREE,                // Bebas: Eksekusi Setiap Ada Sinyal Bar (Tanpa Ditahan Jarak)
   STEP_MIN_DISTANCE,        // Minimum Distance: Jarak Minimal X Poin dari Order Terakhir
   STEP_AVERAGING_ONLY       // Averaging: Hanya Tambah Layer Saat Floating Minus Sejauh X Poin
};

// 7. Pilihan Mode Progresi Lot Layer (Pilar 2: Lot Sizing)
enum ENUM_LOT_MODE
{
   LOT_FIXED,                // Fixed Lot: Ukuran Lot Selalu Tetap
   LOT_ADDER,                // Lot Adder (+): Tambah Lot Bertahap Tiap Layer (0.01, 0.02, 0.03...)
   LOT_MULTIPLIER            // Lot Multiplier (x): Kalikan Lot Tiap Layer (misal 1.2x, 1.5x...)
};

// 8. Pilihan Mode Perhitungan Berdasarkan Angka ($ USD) atau Persentase (% Saldo)
enum ENUM_BASKET_TYPE
{
   BASKET_USD,           // Berdasarkan Angka Nominal ($ Tunai)
   BASKET_PERCENT        // Berdasarkan Persentase (% Saldo)
};

// Nama Objek 6 Garis & Label di Chart (Exposure BUY, Exposure SELL, BEP, TP, Batas Rugi/SL, Stop Out/SO)
#define LINE_EXP_BUY_NAME   "GT_Line_ExposureBuy"
#define LINE_EXP_SELL_NAME  "GT_Line_ExposureSell"
#define LINE_BEP_NAME       "GT_Line_Breakeven"
#define LINE_TP_NAME        "GT_Line_TargetProfit"
#define LINE_SL_NAME        "GT_Line_BasketSL"
#define LINE_SO_NAME        "GT_Line_StopOut"

#define LABEL_EXP_BUY_NAME  "GT_Label_ExposureBuy"
#define LABEL_EXP_SELL_NAME "GT_Label_ExposureSell"
#define LABEL_BEP_NAME      "GT_Label_Breakeven"
#define LABEL_TP_NAME       "GT_Label_TargetProfit"
#define LABEL_SL_NAME       "GT_Label_BasketSL"
#define LABEL_SO_NAME       "GT_Label_StopOut"

#define FUTURE_OBJ_PREFIX   "GT_FutureBox_"

//+------------------------------------------------------------------+
//| PARAMETER INPUT                                                  |
//+------------------------------------------------------------------+
input group "=== [1. PENGATURAN KERANJANG & SAPU BERSIH] ==="
input bool                  InpCloseAllMagic         = true;                    // SAPU BERSIH: Hitung & Tutup SEMUA Posisi Lama?
input bool                  InpAllSymbols            = false;                   // Pantau Semua Pair? (false = Hanya Simbol Ini)
input ulong                 InpMagicNumber           = 999111;                  // Magic Number

input group "=== [2. PROYEKSI KOTAK MASA DEPAN & PENDING ORDER (+1, +2, +3)] ==="
input bool                  InpAutoFollowChartTF     = true;                    // Otomatis Ikuti Timeframe Chart (M1/M5/M15/M30/H1)?
input ENUM_EXEC_ORDER_TYPE  InpExecOrderType         = EXEC_MARKET_LIMIT_STOP;  // Mode Eksekusi (Market + Pending Limit/Stop)
input int                   InpHistoryBarsToRead     = 120;                     // Jumlah Kotak Historis ke Belakang (Default 120 Bar = 2 Jam M1)                       // Jumlah Kotak Historis ke Belakang (misal 4 kotak)
input int                   InpFutureBarsToProject   = 3;                       // Jumlah Kotak Masa Depan Diproyeksikan (misal 3 kotak)
input bool                  InpDrawFutureBoxes       = true;                    // Gambar Kotak Proyeksi Masa Depan di Kanan Chart?
input bool                  InpRefreshPendingEachBar = true;                    // Perbarui Pending Order Otomatis Tiap Pergantian Bar?
input color                 InpColorFutureBull       = clrLimeGreen;            // Warna Kotak Proyeksi Masa Depan NAIK
input color                 InpColorFutureBear       = clrDeepPink;             // Warna Kotak Proyeksi Masa Depan TURUN

input group "=== [3. KONTROL LAYER, JARAK ORDER, & PROGRESI LOT (PILAR 2)] ==="
input ENUM_BASKET_DIRECTION InpBasketDirection       = BASKET_MIXED_ANTI_LOCK;  // Mode Arah Keranjang (Anti-Kunci / 1 Arah / Pisah)
input ENUM_STEP_MODE        InpLayerStepMode         = STEP_FREE;               // Mode Filter Jarak Antar Posisi (STEP_FREE = Langsung Entry)
input double                InpLayerMinStepPoints    = 50.0;                    // Jarak Minimal Antar Order (Jika Mode Distance/Averaging)
input ENUM_LOT_MODE         InpLotMode               = LOT_FIXED;               // Mode Ukuran Lot Layer
input double                InpLotSize               = 0.01;                    // Ukuran Lot Awal (Layer 1)
input double                InpLotAddValue           = 0.01;                    // Nilai Tambah Lot (Jika Mode LOT_ADDER)
input double                InpLotMultiplier         = 1.3;                     // Pengali Lot (Jika Mode LOT_MULTIPLIER)
input double                InpMaxLotSize            = 0.50;                    // Pengaman Batas Maksimal Lot Per Order
input bool                  InpAutoOvertakeBreakRev  = true;                    // Otomatis Balik Arah Lot Saat Sinyal Breakout/Reversal?
input double                InpOvertakeLotFactor     = 1.5;                     // Faktor Pengali Exposure Lawan Saat Balik Arah
input int                   InpMaxOpenPositions      = 50;                      // Maksimal Posisi Terbuka Bersamaan

input group "=== [4. PILIHAN MODE SINYAL ANATOMI TABRANIJ (PILAR 1)] ==="
input ENUM_TIMEFRAMES       InpCustomTF              = PERIOD_CURRENT;          // Timeframe Manual (Jika InpAutoFollowChartTF = false)
input ENUM_ENTRY_MODE       InpEntryMode             = MODE_SMART_HYBRID;       // Mode Sinyal Anatomi Tabranij
input ENUM_EKOR_DIRECTION   InpEkorDirection         = EKOR_EKA_BUY_EKB_SELL;   // Arah Sinyal Ekor: eka=Buy/ekb=Sell atau ekb=Buy/eka=Sell
input double                InpMinNetoPoints         = 0.0;                     // Filter Minimal Panjang Neto (Poin, 0 = Bebas)
input double                InpMinEfficiencyRatio    = 35.0;                    // Minimal Efisiensi Neto % (Utk Trend & Breakout)
input double                InpMinRejectionRatio     = 35.0;                    // Minimal Rasio Ekor % (Utk eka / ekb & Sweep)
input int                   InpLookbackBars          = 3;                       // Jumlah Bar Acuan Tinggi (T) & Rendah (R) (Breakout/Reversal)

input group "=== [5. KOMPAS MULTI-TIMEFRAME (MTF TABRANIJ)] ==="
input ENUM_MTF_MODE         InpCompassMTFMode        = MTF_OFF;                 // Mode Filter Kompas TF Besar (MTF_OFF = Langsung Entry)
input ENUM_TIMEFRAMES       InpTrendTF               = PERIOD_M15;              // Timeframe Kompas Tren Besar (Otomatis Naik Jika Chart >= M15)
input int                   InpHTFLookbackBars       = 3;                       // Jumlah Bar Acuan Breakout di TF Besar

input group "=== [6. TARGET PROFIT KERANJANG (ANGKA / PERSENTASE)] ==="
input ENUM_BASKET_TYPE      InpTPType                = BASKET_USD;              // Mode Target Profit (Angka $ atau % Saldo)
input double                InpTargetUSD             = 5.0;                     // Target Profit ($ Tunai)
input double                InpTargetPercent         = 0.5;                     // Target Profit (% Saldo)

input group "=== [7. BATAS RUGI / CUT LOSS (ANGKA / PERSENTASE)] ==="
input bool                  InpUseBasketSL           = true;                    // Aktifkan Cut Loss Saat Batas Rugi Tersentuh?
input ENUM_BASKET_TYPE      InpSLType                = BASKET_USD;              // Mode Batas Rugi (Angka $ atau % Saldo)
input double                InpMaxLossUSD            = 15.0;                    // Batas Maksimal Rugi ($ Tunai)
input double                InpMaxLossPercent        = 1.5;                     // Batas Maksimal Rugi (% Saldo)

input group "=== [8. VISUALISASI 6 GARIS (EXPOSURE BUY/SELL, BEP, TP, SL, SO)] ==="
input bool                  InpShowChartLines        = true;                    // Tampilkan Garis di Chart?
input bool                  InpShowLineLabels        = true;                    // Tampilkan Teks Keterangan di Atas Garis?
input bool                  InpShowExposureLines     = true;                    // Tampilkan Garis Exposure BUY & Exposure SELL?
input bool                  InpShowSOLine            = true;                    // Tampilkan Garis Stop Out (SO) Broker?
input color                 InpColorExpBuy           = clrDodgerBlue;           // Warna Garis Exposure BUY (Rata-Rata/BEP Buy)
input color                 InpColorExpSell          = clrTomato;               // Warna Garis Exposure SELL (Rata-Rata/BEP Sell)
input color                 InpColorBEP              = clrGold;                 // Warna Garis Breakeven Gabungan (Net BEP)
input color                 InpColorTP               = clrLime;                 // Warna Garis Target Profit (TP)
input color                 InpColorSL               = clrOrangeRed;            // Warna Garis Batas Rugi (Cut Loss / SL)
input color                 InpColorSO               = clrMagenta;              // Warna Garis Stop Out (SO Ketahanan Akun)
input ENUM_LINE_STYLE       InpLineStyle             = STYLE_SOLID;             // Gaya Garis Utama (Solid / Dash / Dot)
input int                   InpLineWidth             = 2;                       // Ketebalan Garis Utama (1 - 5)

input group "=== [9. NOTIFIKASI SUARA] ==="
input bool                  InpEnableSound           = true;                    // Aktifkan Suara?
input string                InpSoundBuy              = "ok.wav";                // Suara Order BUY
input string                InpSoundSell             = "expert.wav";            // Suara Order SELL
input string                InpSoundTP               = "alert.wav";             // Suara Saat Profit Tercapai
input string                InpSoundSL               = "stops.wav";             // Suara Saat Batas Rugi Terkena

input group "=== [10. MIKRO-SIKLUS 10 DETIK & TINGKAT LOT (OPSI 1, 2, 3)] ==="
input bool                  InpEnable10SecCycle      = true;                    // Aktifkan Pemicu Mikro 10 Detik? (Eksekusi Detik 10,20,30,40,50,00)
input int                   InpLookback6Boxes        = 6;                       // Acuan Kotak M1 utk Breakout/Sweep (Opsi 3)
input double                InpBoosterLotMultiplier  = 2.0;                     // Pengali Lot Booster Melampaui 6 Kotak (Opsi 3)
input bool                  InpEnableFollowM1        = true;                    // Opsi 1: Follow Tren M1 (Searah Lilin Hijau/Merah)
input bool                  InpEnableRejectionM1     = true;                    // Opsi 2: Pantulan Ekor M1 (Rejection Atap/Lantai)

datetime last_exec_bar_time   = 0;
string   g_last_signal_info   = "Siap Mengeksekusi Sinyal...";
string   g_last_order_comment = "-";
string   g_mtf_status_info    = "MTF OFF (Bebas 2 Arah)";
string   g_timeline_info      = "Memuat Riwayat Timeframe...";
string   g_future_boxes_info  = "Menghitung Kotak Proyeksi...";
double   g_last_tick_bid          = 0.0;
int      g_window_up_ticks        = 0;
int      g_window_down_ticks      = 0;
int      g_last_eval_up_ticks     = 0;
int      g_last_eval_down_ticks   = 0;
long     g_last_10s_window_key    = -1;
string   g_micro_cycle_info       = "10s Mikro: Standby Menghitung Tick...";

//+------------------------------------------------------------------+
//| Dapatkan Timeframe Eksekusi Aktif (Selalu Ikuti Chart _Period)   |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES GetExecTF()
{
   if(InpAutoFollowChartTF || InpCustomTF == PERIOD_CURRENT)
      return _Period;
   return InpCustomTF;
}

//+------------------------------------------------------------------+
//| Dapatkan Timeframe Kompas HTF (Otomatis Naik Jika Chart >= HTF)  |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES GetEffectiveTrendTF()
{
   ENUM_TIMEFRAMES exec_tf  = GetExecTF();
   ENUM_TIMEFRAMES trend_tf = (InpTrendTF == PERIOD_CURRENT) ? _Period : InpTrendTF;

   if(PeriodSeconds(trend_tf) <= PeriodSeconds(exec_tf))
   {
      int sec = PeriodSeconds(exec_tf);
      if(sec < 300)        return PERIOD_M15; // Jika M1 -> Kompas M15
      if(sec < 900)        return PERIOD_M30; // Jika M5 -> Kompas M30
      if(sec < 1800)       return PERIOD_H1;  // Jika M15 -> Kompas H1
      if(sec < 3600)       return PERIOD_H4;  // Jika M30 -> Kompas H4
      if(sec < 14400)      return PERIOD_H4;  // Jika H1 -> Kompas H4
      return PERIOD_D1;                       // Jika >= H4 -> Kompas D1
   }
   return trend_tf;
}

//+------------------------------------------------------------------+
//| Ambil Menit/Jam Singkat untuk Label Waktu di Semua Timeframe     |
//+------------------------------------------------------------------+
string GetShortBarTimeLabel(datetime bar_time, ENUM_TIMEFRAMES tf)
{
   MqlDateTime dt;
   TimeToStruct(bar_time, dt);
   int sec = PeriodSeconds(tf);

   if(sec <= 60)
      return StringFormat("m%02d", dt.min);
   if(sec < 86400)
      return StringFormat("%02d:%02d", dt.hour, dt.min);
   return StringFormat("%02d/%02d", dt.day, dt.mon);
}

//+------------------------------------------------------------------+
//| Hitung Proyeksi Kotak Masa Depan (+1, +2, +3...) di Semua TF     |
//+------------------------------------------------------------------+
bool CalculateFutureProjections(Tabranij &future_boxes[], string &out_timeline_str, string &out_future_str)
{
   // Visual proyeksi selalu mengikuti Timeframe Chart yang sedang dibuka (_Period: M1, M5, M15, M30, H1, dst.)
   ENUM_TIMEFRAMES tf = GetExecTF();
   int hist_count     = MathMax(2, InpHistoryBarsToRead);
   int future_count   = MathMax(1, MathMin(10, InpFutureBarsToProject));
   ArrayResize(future_boxes, future_count);

   Tabranij t0 = HitungTabranij(_Symbol, tf, 0); // Kotak Live sekarang pada TF aktif
   if(t0.Waktu == 0 || t0.I <= 0.0) return false;

   double sum_weight      = 0.0;
   double weighted_vektor = 0.0;
   double weighted_neto   = 0.0;
   double weighted_julat  = 0.0;
   double weighted_eka    = 0.0;
   double weighted_ekb    = 0.0;

   string past_labels = "";

   for(int s = hist_count; s >= 1; s--)
   {
      Tabranij th = HitungTabranij(_Symbol, tf, s);
      if(th.Waktu == 0) continue;

      double w = (double)(hist_count - s + 1); // Bobot bertingkat
      sum_weight      += w;
      weighted_vektor += th.VektorNeto * w;
      weighted_neto   += th.N          * w;
      weighted_julat  += th.J          * w;
      weighted_eka    += th.EkorAtas   * w;
      weighted_ekb    += th.EkorBawah  * w;

      past_labels += GetShortBarTimeLabel(th.Waktu, tf) + (s > 1 ? ", " : "");
   }

   // Fallback ke t0 jika riwayat TF baru sedang sinkronisasi di MT5
   if(sum_weight <= 0.0)
   {
      sum_weight      = 1.0;
      weighted_vektor = t0.VektorNeto;
      weighted_neto   = MathMax(t0.N, 20.0 * _Point);
      weighted_julat  = MathMax(t0.J, 40.0 * _Point);
      weighted_eka    = MathMax(t0.EkorAtas,  10.0 * _Point);
      weighted_ekb    = MathMax(t0.EkorBawah, 10.0 * _Point);
      past_labels     = "Sync...";
   }

   double avg_vektor = weighted_vektor / sum_weight;
   double avg_neto   = MathMax(weighted_neto / sum_weight, 15.0 * _Point);
   double avg_julat  = MathMax(weighted_julat / sum_weight, 30.0 * _Point);
   double avg_eka    = MathMax(weighted_eka   / sum_weight,  8.0 * _Point);
   double avg_ekb    = MathMax(weighted_ekb   / sum_weight,  8.0 * _Point);

   // Gabungkan kecepatan historis (65%) dengan kecepatan Live Bar 0 saat ini (35%)
   double live_step_vektor = (avg_vektor * 0.65) + (t0.VektorNeto * 0.35);

   // Pastikan ukuran body proyeksi minimal 45% dari rata-rata Neto agar kotak masa depan tampak jelas di semua TF
   double dir_sign = (live_step_vektor >= 0.0) ? 1.0 : -1.0;
   if(MathAbs(live_step_vektor) < avg_neto * 0.45)
      live_step_vektor = dir_sign * MathMax(avg_neto * 0.55, 15.0 * _Point);

   int period_sec = PeriodSeconds(tf);
   if(period_sec <= 0) period_sec = PeriodSeconds(_Period);
   if(period_sec <= 0) period_sec = 60;

   double next_awal = t0.I; // Titik Awal kotak +1 dimulai dari Inti Live saat ini

   out_future_str = "";
   string future_labels = "";

   for(int k = 0; k < future_count; k++)
   {
      Tabranij fp;
      ZeroMemory(fp);

      fp.Waktu = t0.Waktu + (datetime)((k + 1) * period_sec);
      fp.Awal  = NormalizeDouble(next_awal, _Digits);

      double damp   = MathPow(0.92, k);
      double step_v = live_step_vektor * damp;

      fp.I = NormalizeDouble(fp.Awal + step_v, _Digits);
      fp.AtapBadan   = MathMax(fp.Awal, fp.I);
      fp.LantaiBadan = MathMin(fp.Awal, fp.I);
      fp.N           = MathAbs(fp.I - fp.Awal);

      fp.A           = NormalizeDouble(avg_eka, _Digits); // Atas
      fp.B           = NormalizeDouble(avg_ekb, _Digits); // Bawah
      fp.EkorAtas    = fp.A;
      fp.EkorBawah   = fp.B;

      fp.T = NormalizeDouble(fp.AtapBadan + fp.A,   _Digits);
      fp.R = NormalizeDouble(fp.LantaiBadan - fp.B, _Digits);
      fp.J = fp.T - fp.R;

      fp.VektorNeto = fp.I - fp.Awal;
      fp.IsNaik     = (fp.I >= fp.Awal);

      if(fp.J > 0.0)
      {
         fp.EfisiensiNeto       = fp.N / fp.J;
         fp.RasioPenolakanAtas  = fp.EkorAtas  / fp.J;
         fp.RasioPenolakanBawah = fp.EkorBawah / fp.J;
      }

      future_boxes[k] = fp;
      next_awal       = fp.I;

      string f_lbl = GetShortBarTimeLabel(fp.Waktu, tf);
      future_labels  += f_lbl + (k < future_count - 1 ? ", " : "");
      out_future_str += StringFormat("[+%d %s %s T:%.2f R:%.2f] ",
                                     k + 1, f_lbl, (fp.IsNaik ? "NAIK" : "TURUN"), fp.T, fp.R);
   }

   out_timeline_str = StringFormat("[%s] Riwayat(%s) -> LIVE[%s] -> Kedepan(%s)",
                                   EnumToString(tf), past_labels,
                                   GetShortBarTimeLabel(t0.Waktu, tf), future_labels);
   return true;
}

//+------------------------------------------------------------------+
//| Hapus Objek Kotak Proyeksi Masa Depan dari Chart                 |
//+------------------------------------------------------------------+
void DeleteFutureBoxObjects()
{
   for(int i = ObjectsTotal(0, 0, -1) - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, 0, -1);
      if(StringFind(name, FUTURE_OBJ_PREFIX) == 0)
         ObjectDelete(0, name);
   }
}

//+------------------------------------------------------------------+
//| Gambar Kotak Proyeksi Masa Depan (+1, +2, +3) di Semua Timeframe |
//+------------------------------------------------------------------+
void DrawFutureBoxesOnChart(const Tabranij &future_boxes[])
{
   if(!InpDrawFutureBoxes || (MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE)))
   {
      DeleteFutureBoxObjects();
      return;
   }

   ENUM_TIMEFRAMES chart_tf = _Period;
   int count      = ArraySize(future_boxes);
   int period_sec = PeriodSeconds(chart_tf);
   if(period_sec <= 0) period_sec = 60;

   datetime bar0_time = iTime(_Symbol, chart_tf, 0);
   if(bar0_time == 0) bar0_time = TimeCurrent();

   for(int k = 0; k < count; k++)
   {
      Tabranij fp = future_boxes[k];
      if(fp.T <= 0.0 || fp.R <= 0.0) continue;

      // Pastikan koordinat waktu selalu sejajar dengan grid bar chart aktif (_Period)
      datetime t_start = bar0_time + (datetime)((k + 1) * period_sec);
      datetime t_end   = bar0_time + (datetime)((k + 2) * period_sec);

      string range_name = FUTURE_OBJ_PREFIX + "Range_" + IntegerToString(k + 1);
      string body_name  = FUTURE_OBJ_PREFIX + "Body_"  + IntegerToString(k + 1);
      string wick_name  = FUTURE_OBJ_PREFIX + "Wick_"  + IntegerToString(k + 1);
      string label_name = FUTURE_OBJ_PREFIX + "Label_" + IntegerToString(k + 1);

      color  box_color = fp.IsNaik ? InpColorFutureBull : InpColorFutureBear;
      string time_lbl  = GetShortBarTimeLabel(t_start, chart_tf);
      string tooltip   = StringFormat("Proyeksi +%d (%s) | T: %.2f | A: %.2f | B: %.2f | R: %.2f",
                                      k + 1, time_lbl, fp.T, fp.A, fp.B, fp.R);

      // 1. Kotak Bingkai Luar Julat (Tinggi T ke Rendah R) - Outline Putus-Putus
      if(ObjectFind(0, range_name) < 0)
      {
         ObjectCreate(0, range_name, OBJ_RECTANGLE, 0, t_start, fp.T, t_end, fp.R);
         ObjectSetInteger(0, range_name, OBJPROP_FILL, false);
         ObjectSetInteger(0, range_name, OBJPROP_BACK, false);
         ObjectSetInteger(0, range_name, OBJPROP_SELECTABLE, false);
      }
      ObjectMove(0, range_name, 0, t_start, fp.T);
      ObjectMove(0, range_name, 1, t_end,   fp.R);
      ObjectSetInteger(0, range_name, OBJPROP_COLOR, box_color);
      ObjectSetInteger(0, range_name, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, range_name, OBJPROP_WIDTH, 1);
      ObjectSetString(0, range_name, OBJPROP_TOOLTIP, tooltip);

      // 2. Kotak Dalam Badan Neto (Atas A ke Bawah B) - Blok Berwarna
      if(ObjectFind(0, body_name) < 0)
      {
         ObjectCreate(0, body_name, OBJ_RECTANGLE, 0, t_start, fp.AtapBadan, t_end, fp.LantaiBadan);
         ObjectSetInteger(0, body_name, OBJPROP_FILL, true);
         ObjectSetInteger(0, body_name, OBJPROP_BACK, true);
         ObjectSetInteger(0, body_name, OBJPROP_SELECTABLE, false);
      }
      ObjectMove(0, body_name, 0, t_start, fp.AtapBadan);
      ObjectMove(0, body_name, 1, t_end,   fp.LantaiBadan);
      ObjectSetInteger(0, body_name, OBJPROP_COLOR, box_color);
      ObjectSetInteger(0, body_name, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, body_name, OBJPROP_WIDTH, 2);
      ObjectSetString(0, body_name, OBJPROP_TOOLTIP, tooltip);

      // 3. Garis Vertikal Ekor (T ke R)
      if(ObjectFind(0, wick_name) < 0)
      {
         ObjectCreate(0, wick_name, OBJ_TREND, 0, t_start, fp.T, t_start, fp.R);
         ObjectSetInteger(0, wick_name, OBJPROP_RAY_RIGHT, false);
         ObjectSetInteger(0, wick_name, OBJPROP_RAY_LEFT, false);
         ObjectSetInteger(0, wick_name, OBJPROP_SELECTABLE, false);
      }
      ObjectMove(0, wick_name, 0, t_start, fp.T);
      ObjectMove(0, wick_name, 1, t_start, fp.R);
      ObjectSetInteger(0, wick_name, OBJPROP_COLOR, box_color);
      ObjectSetInteger(0, wick_name, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, wick_name, OBJPROP_WIDTH, 2);
      ObjectSetString(0, wick_name, OBJPROP_TOOLTIP, tooltip);

      // 4. Label Teks di Atas Kotak Proyeksi (+1, +2, +3)
      if(ObjectFind(0, label_name) < 0)
      {
         ObjectCreate(0, label_name, OBJ_TEXT, 0, t_start, fp.T);
         ObjectSetInteger(0, label_name, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
         ObjectSetString(0, label_name, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, label_name, OBJPROP_FONTSIZE, 8);
         ObjectSetInteger(0, label_name, OBJPROP_SELECTABLE, false);
      }
      ObjectMove(0, label_name, 0, t_start, fp.T + (5 * _Point));
      ObjectSetInteger(0, label_name, OBJPROP_COLOR, box_color);
      ObjectSetString(0, label_name, OBJPROP_TEXT, StringFormat("+%d(%s)", k + 1, time_lbl));
   }

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Inisialisasi Mode Eksekusi Awal                                  |
//+------------------------------------------------------------------+
void InitTradeEngine()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(50);

   uint filling = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) != 0)
      trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((filling & SYMBOL_FILLING_IOC) != 0)
      trade.SetTypeFilling(ORDER_FILLING_IOC);
   else
      trade.SetTypeFilling(ORDER_FILLING_RETURN);
}

//+------------------------------------------------------------------+
//| Normalisasi Ukuran Lot Sesuai Aturan Broker & Pengaman Max Lot   |
//+------------------------------------------------------------------+
double NormalizeLot(double raw_lot)
{
   double min_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lot_step <= 0.0) lot_step = 0.01;
   if(min_lot  <= 0.0) min_lot  = 0.01;

   double lot = raw_lot;
   if(InpMaxLotSize > 0.0 && lot > InpMaxLotSize)
      lot = InpMaxLotSize;

   if(lot < min_lot) lot = min_lot;
   if(max_lot > 0.0 && lot > max_lot) lot = max_lot;

   lot = MathFloor((lot + 0.0000001) / lot_step) * lot_step;

   int lot_digits = 2;
   if(lot_step >= 1.0)        lot_digits = 0;
   else if(lot_step >= 0.1)   lot_digits = 1;
   else if(lot_step >= 0.01)  lot_digits = 2;
   else if(lot_step >= 0.001) lot_digits = 3;

   return NormalizeDouble(lot, lot_digits);
}

//+------------------------------------------------------------------+
//| Hitung Ukuran Lot Berikutnya Berdasarkan Layer, Exposure & Sinyal|
//+------------------------------------------------------------------+
double CalculateNextLot(bool is_buy, bool is_breakout_or_reversal, const BasketExposure &exp, bool is_booster_tier = false)
{
   int same_side_count = is_buy ? exp.buy_count : exp.sell_count;
   double raw_lot = InpLotSize;

   if(same_side_count > 0)
   {
      if(InpLotMode == LOT_ADDER)
         raw_lot = InpLotSize + (same_side_count * InpLotAddValue);
      else if(InpLotMode == LOT_MULTIPLIER)
         raw_lot = InpLotSize * MathPow(InpLotMultiplier, same_side_count);
   }

   // TINGKAT 2: Booster Lot Melampaui 6 Kotak M1 (Opsi 3)
   if(is_booster_tier && InpBoosterLotMultiplier > 1.0)
   {
      raw_lot = raw_lot * InpBoosterLotMultiplier;
   }

   if(InpAutoOvertakeBreakRev && is_breakout_or_reversal && InpBasketDirection != BASKET_ONE_WAY)
   {
      if(is_buy && exp.net_lots < -0.00001)
      {
         double overtake_lot = MathAbs(exp.net_lots) * InpOvertakeLotFactor;
         if(overtake_lot > raw_lot) raw_lot = overtake_lot;
      }
      else if(!is_buy && exp.net_lots > 0.00001)
      {
         double overtake_lot = MathAbs(exp.net_lots) * InpOvertakeLotFactor;
         if(overtake_lot > raw_lot) raw_lot = overtake_lot;
      }
   }

   double final_lot = NormalizeLot(raw_lot);

   if(InpBasketDirection == BASKET_MIXED_ANTI_LOCK)
   {
      double projected_buy_lots  = exp.buy_lots  + (is_buy  ? final_lot : 0.0);
      double projected_sell_lots = exp.sell_lots + (!is_buy ? final_lot : 0.0);

      if(MathAbs(projected_buy_lots - projected_sell_lots) < 0.00001)
      {
         double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
         if(step <= 0.0) step = 0.01;
         final_lot = NormalizeLot(final_lot + step);
      }
   }

   return final_lot;
}

//+------------------------------------------------------------------+
//| Validasi Arah Keranjang & Jarak Minimal Antar Posisi (Pilar 2)   |
//+------------------------------------------------------------------+
bool CheckLayerAndStepPermission(bool is_buy, bool is_breakout_or_reversal,
                                 const BasketExposure &exp, string &out_block_reason)
{
   out_block_reason = "";

   if(InpBasketDirection == BASKET_ONE_WAY)
   {
      if(is_buy && exp.sell_count > 0 && exp.buy_count == 0)
      {
         out_block_reason = "Ditahan One-Way: Keranjang sedang fokus SELL";
         return false;
      }
      if(!is_buy && exp.buy_count > 0 && exp.sell_count == 0)
      {
         out_block_reason = "Ditahan One-Way: Keranjang sedang fokus BUY";
         return false;
      }
   }

   if(InpAutoOvertakeBreakRev && is_breakout_or_reversal)
   {
      if((is_buy && exp.net_lots < -0.00001) || (!is_buy && exp.net_lots > 0.00001))
         return true;
   }

   if(InpLayerStepMode == STEP_FREE || InpLayerMinStepPoints <= 0.0)
      return true;

   double min_dist_price = InpLayerMinStepPoints * _Point;

   if(is_buy && exp.buy_count > 0)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(InpLayerStepMode == STEP_AVERAGING_ONLY)
      {
         double dist_pts = (exp.lowest_buy_price - ask) / _Point;
         if((exp.lowest_buy_price - ask) < min_dist_price)
         {
            out_block_reason = StringFormat("Menunggu Jarak Averaging BUY (%.0f < %.0f pts)", dist_pts, InpLayerMinStepPoints);
            return false;
         }
      }
      else if(InpLayerStepMode == STEP_MIN_DISTANCE)
      {
         double dist_pts = MathAbs(ask - exp.last_buy_price) / _Point;
         if(MathAbs(ask - exp.last_buy_price) < min_dist_price)
         {
            out_block_reason = StringFormat("Menunggu Jarak BUY (%.0f < %.0f pts)", dist_pts, InpLayerMinStepPoints);
            return false;
         }
      }
   }
   else if(!is_buy && exp.sell_count > 0)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(InpLayerStepMode == STEP_AVERAGING_ONLY)
      {
         double dist_pts = (bid - exp.highest_sell_price) / _Point;
         if((bid - exp.highest_sell_price) < min_dist_price)
         {
            out_block_reason = StringFormat("Menunggu Jarak Averaging SELL (%.0f < %.0f pts)", dist_pts, InpLayerMinStepPoints);
            return false;
         }
      }
      else if(InpLayerStepMode == STEP_MIN_DISTANCE)
      {
         double dist_pts = MathAbs(bid - exp.last_sell_price) / _Point;
         if(MathAbs(bid - exp.last_sell_price) < min_dist_price)
         {
            out_block_reason = StringFormat("Menunggu Jarak SELL (%.0f < %.0f pts)", dist_pts, InpLayerMinStepPoints);
            return false;
         }
      }
   }

   return true;
}

//+------------------------------------------------------------------+
//| Eksekusi Pintar Market Order (Auto-Coba Seluruh Filling Mode)    |
//+------------------------------------------------------------------+
bool SafeExecute(bool is_buy, double volume, string comment)
{
   double price = is_buy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool success = false;

   if(is_buy)
      success = trade.Buy(volume, _Symbol, price, 0, 0, comment);
   else
      success = trade.Sell(volume, _Symbol, price, 0, 0, comment);

   if(!success && trade.ResultRetcode() == 10030)
   {
      ENUM_ORDER_TYPE_FILLING alternate_modes[3] = {ORDER_FILLING_IOC, ORDER_FILLING_RETURN, ORDER_FILLING_FOK};

      for(int i = 0; i < 3; i++)
      {
         trade.SetTypeFilling(alternate_modes[i]);
         price = is_buy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

         if(is_buy)
            success = trade.Buy(volume, _Symbol, price, 0, 0, comment);
         else
            success = trade.Sell(volume, _Symbol, price, 0, 0, comment);

         if(success) break;
      }
   }

   if(!success)
   {
      Print("[SafeExecute Gagal] ", (is_buy ? "BUY " : "SELL "), volume, " Lot | Retcode: ",
            trade.ResultRetcode(), " (", trade.ResultRetcodeDescription(), ")");
   }

   return success;
}

//+------------------------------------------------------------------+
//| Hapus Semua Pending Order yang Dipasang oleh EA                  |
//+------------------------------------------------------------------+
void DeleteAllPendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong order_ticket = OrderGetTicket(i);
      if(order_ticket > 0)
      {
         string sym   = OrderGetString(ORDER_SYMBOL);
         long   magic = OrderGetInteger(ORDER_MAGIC);
         if((InpAllSymbols || sym == _Symbol) && (InpCloseAllMagic || magic == (long)InpMagicNumber || magic == 0))
         {
            trade.OrderDelete(order_ticket);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Pasang Pending Order Limit / Stop Berdasarkan Kotak Masa Depan   |
//+------------------------------------------------------------------+
int PlaceFuturePendingOrders(bool is_buy_signal, double lot, const Tabranij &future_boxes[])
{
   int count = ArraySize(future_boxes);
   if(count <= 0) return 0;

   bool use_limit = (InpExecOrderType == EXEC_MARKET_AND_LIMIT ||
                     InpExecOrderType == EXEC_MARKET_LIMIT_STOP ||
                     InpExecOrderType == EXEC_PENDING_LIMIT_ONLY ||
                     InpExecOrderType == EXEC_PENDING_BOTH_ONLY);

   bool use_stop  = (InpExecOrderType == EXEC_MARKET_AND_STOP ||
                     InpExecOrderType == EXEC_MARKET_LIMIT_STOP ||
                     InpExecOrderType == EXEC_PENDING_STOP_ONLY ||
                     InpExecOrderType == EXEC_PENDING_BOTH_ONLY);

   if(!use_limit && !use_stop) return 0;

   ENUM_TIMEFRAMES exec_tf = GetExecTF();
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spread = MathMax(ask - bid, 10.0 * _Point);

   long   stop_lvl_pts   = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long   freeze_lvl_pts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double broker_min     = (double)MathMax(stop_lvl_pts, freeze_lvl_pts) * _Point;
   double min_offset     = MathMax(broker_min + spread, 35.0 * _Point);
   double step_gap       = MathMax(InpLayerMinStepPoints * 0.5 * _Point, 35.0 * _Point);

   int placed_count = 0;

   for(int k = 0; k < count; k++)
   {
      Tabranij fp  = future_boxes[k];
      string t_lbl = GetShortBarTimeLabel(fp.Waktu, exec_tf);

      if(is_buy_signal)
      {
         // 1. BUY LIMIT di Proyeksi Rendah (R) Kotak Masa Depan (+1, +2, +3)
         if(use_limit)
         {
            double lim_price           = fp.R;
            double max_allowed_buy_lim = ask - min_offset - (k * step_gap);
            if(lim_price > max_allowed_buy_lim) lim_price = max_allowed_buy_lim;
            lim_price = NormalizeDouble(lim_price, _Digits);

            string comment = StringFormat("GT BuyLim R+%d (%s)", k + 1, t_lbl);
            if(trade.BuyLimit(lot, lim_price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, comment))
            {
               placed_count++;
               Print("[Pending GT] ", comment, " dipasang @ ", DoubleToString(lim_price, _Digits));
            }
         }

         // 2. BUY STOP di Proyeksi Tinggi (T) Kotak Masa Depan (+1, +2, +3)
         if(use_stop)
         {
            double stp_price           = fp.T;
            double min_allowed_buy_stp = ask + min_offset + (k * step_gap);
            if(stp_price < min_allowed_buy_stp) stp_price = min_allowed_buy_stp;
            stp_price = NormalizeDouble(stp_price, _Digits);

            string comment = StringFormat("GT BuyStop T+%d (%s)", k + 1, t_lbl);
            if(trade.BuyStop(lot, stp_price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, comment))
            {
               placed_count++;
               Print("[Pending GT] ", comment, " dipasang @ ", DoubleToString(stp_price, _Digits));
            }
         }
      }
      else // Sinyal SELL
      {
         // 1. SELL LIMIT di Proyeksi Tinggi (T) Kotak Masa Depan (+1, +2, +3)
         if(use_limit)
         {
            double lim_price            = fp.T;
            double min_allowed_sell_lim = bid + min_offset + (k * step_gap);
            if(lim_price < min_allowed_sell_lim) lim_price = min_allowed_sell_lim;
            lim_price = NormalizeDouble(lim_price, _Digits);

            string comment = StringFormat("GT SellLim T+%d (%s)", k + 1, t_lbl);
            if(trade.SellLimit(lot, lim_price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, comment))
            {
               placed_count++;
               Print("[Pending GT] ", comment, " dipasang @ ", DoubleToString(lim_price, _Digits));
            }
         }

         // 2. SELL STOP di Proyeksi Rendah (R) Kotak Masa Depan (+1, +2, +3)
         if(use_stop)
         {
            double stp_price            = fp.R;
            double max_allowed_sell_stp = bid - min_offset - (k * step_gap);
            if(stp_price > max_allowed_sell_stp) stp_price = max_allowed_sell_stp;
            stp_price = NormalizeDouble(stp_price, _Digits);

            string comment = StringFormat("GT SellStop R+%d (%s)", k + 1, t_lbl);
            if(trade.SellStop(lot, stp_price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, comment))
            {
               placed_count++;
               Print("[Pending GT] ", comment, " dipasang @ ", DoubleToString(stp_price, _Digits));
            }
         }
      }
   }

   return placed_count;
}

//+------------------------------------------------------------------+
//| Filter Validasi Posisi (Bisa Sapu Bersih Semua Magic Number)     |
//+------------------------------------------------------------------+
bool IsPositionEligible(ulong ticket)
{
   if(ticket <= 0) return false;

   string pos_symbol = PositionGetString(POSITION_SYMBOL);
   long   pos_magic  = PositionGetInteger(POSITION_MAGIC);

   if(!InpAllSymbols && pos_symbol != _Symbol) return false;
   if(InpCloseAllMagic) return true;
   if(pos_magic == (long)InpMagicNumber || pos_magic == 0) return true;

   return false;
}

//+------------------------------------------------------------------+
//| Kumpulkan Data Exposure BUY, SELL & Pending Order Lengkap        |
//+------------------------------------------------------------------+
void CollectBasketExposure(BasketExposure &exp)
{
   ZeroMemory(exp);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && IsPositionEligible(ticket))
      {
         double pos_profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         exp.total_profit += pos_profit;
         exp.total_count++;

         if(PositionGetString(POSITION_SYMBOL) == _Symbol)
         {
            double   vol        = PositionGetDouble(POSITION_VOLUME);
            double   open_price = PositionGetDouble(POSITION_PRICE_OPEN);
            datetime open_time  = (datetime)PositionGetInteger(POSITION_TIME);
            long     type       = PositionGetInteger(POSITION_TYPE);

            if(type == POSITION_TYPE_BUY)
            {
               exp.buy_count++;
               exp.buy_lots   += vol;
               exp.buy_profit += pos_profit;

               if(exp.lowest_buy_price == 0.0 || open_price < exp.lowest_buy_price)
                  exp.lowest_buy_price = open_price;

               if(open_time >= exp.last_buy_time)
               {
                  exp.last_buy_time  = open_time;
                  exp.last_buy_price = open_price;
               }
            }
            else if(type == POSITION_TYPE_SELL)
            {
               exp.sell_count++;
               exp.sell_lots   += vol;
               exp.sell_profit += pos_profit;

               if(exp.highest_sell_price == 0.0 || open_price > exp.highest_sell_price)
                  exp.highest_sell_price = open_price;

               if(open_time >= exp.last_sell_time)
               {
                  exp.last_sell_time  = open_time;
                  exp.last_sell_price = open_price;
               }
            }
         }
      }
   }

   for(int j = OrdersTotal() - 1; j >= 0; j--)
   {
      ulong order_ticket = OrderGetTicket(j);
      if(order_ticket > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol)
         exp.pending_count++;
   }

   exp.net_lots = exp.buy_lots - exp.sell_lots;
}

//+------------------------------------------------------------------+
//| Evaluasi Kompas Multi-Timeframe (MTF) Tabranij                   |
//+------------------------------------------------------------------+
void EvaluateMTFCompass(bool &allow_buy, bool &allow_sell, string &mtf_info)
{
   allow_buy  = true;
   allow_sell = true;

   if(InpCompassMTFMode == MTF_OFF)
   {
      mtf_info = "MTF OFF (Bebas 2 Arah)";
      return;
   }

   ENUM_TIMEFRAMES trend_tf = GetEffectiveTrendTF();
   string tf_name = EnumToString(trend_tf);

   if(InpCompassMTFMode == MTF_LIVE_BAR0)
   {
      Tabranij t_htf = HitungTabranij(_Symbol, trend_tf, 0);
      if(t_htf.Waktu == 0)
      {
         mtf_info = tf_name + " (Sinkronisasi...)";
         return;
      }
      allow_buy  = t_htf.IsNaik;
      allow_sell = !t_htf.IsNaik;
      mtf_info   = StringFormat("%s Live(Bar 0): %s (neto %.0f%%)",
                                tf_name, (t_htf.IsNaik ? "BULLISH [BUY]" : "BEARISH [SELL]"),
                                t_htf.EfisiensiNeto * 100.0);
      return;
   }

   if(InpCompassMTFMode == MTF_CLOSED_BAR1)
   {
      Tabranij t_htf = HitungTabranij(_Symbol, trend_tf, 1);
      if(t_htf.Waktu == 0)
      {
         mtf_info = tf_name + " (Sinkronisasi...)";
         return;
      }
      allow_buy  = t_htf.IsNaik;
      allow_sell = !t_htf.IsNaik;
      mtf_info   = StringFormat("%s Closed(Bar 1): %s (neto %.0f%%)",
                                tf_name, (t_htf.IsNaik ? "BULLISH [BUY]" : "BEARISH [SELL]"),
                                t_htf.EfisiensiNeto * 100.0);
      return;
   }

   Tabranij htf0 = HitungTabranij(_Symbol, trend_tf, 0);
   Tabranij htf1 = HitungTabranij(_Symbol, trend_tf, 1);
   if(htf0.Waktu == 0 || htf1.Waktu == 0)
   {
      mtf_info = tf_name + " (Sinkronisasi...)";
      return;
   }

   double htf_high_T = 0.0, htf_low_R = 0.0;
   bool has_range = GetExtremeTR(_Symbol, trend_tf, 2, MathMax(1, InpHTFLookbackBars), htf_high_T, htf_low_R);

   double min_rej = InpMinRejectionRatio / 100.0;

   bool htf_rev_buy  = (htf1.RasioPenolakanBawah >= min_rej && htf1.EkorBawah > htf1.EkorAtas) ||
                       (has_range && htf1.R < htf_low_R && htf1.I > htf_low_R);
   bool htf_rev_sell = (htf1.RasioPenolakanAtas >= min_rej && htf1.EkorAtas > htf1.EkorBawah) ||
                       (has_range && htf1.T > htf_high_T && htf1.I < htf_high_T);

   bool htf_brk_buy  = has_range && (htf0.I > htf1.T || htf1.I > htf_high_T);
   bool htf_brk_sell = has_range && (htf0.I < htf1.R || htf1.I < htf_low_R);

   if(htf_brk_buy)
   {
      allow_buy  = true;
      allow_sell = false;
      mtf_info   = tf_name + ": BREAKOUT ATAS [BUY ONLY]";
   }
   else if(htf_brk_sell)
   {
      allow_buy  = false;
      allow_sell = true;
      mtf_info   = tf_name + ": BREAKOUT BAWAH [SELL ONLY]";
   }
   else if(htf_rev_buy && !htf_rev_sell)
   {
      allow_buy  = true;
      allow_sell = false;
      mtf_info   = tf_name + ": REVERSAL BAWAH [BUY ONLY]";
   }
   else if(htf_rev_sell && !htf_rev_buy)
   {
      allow_buy  = false;
      allow_sell = true;
      mtf_info   = tf_name + ": REVERSAL ATAS [SELL ONLY]";
   }
   else
   {
      allow_buy  = htf0.IsNaik;
      allow_sell = !htf0.IsNaik;
      mtf_info   = StringFormat("%s Trend Normal: %s", tf_name, (htf0.IsNaik ? "NAIK [BUY]" : "TURUN [SELL]"));
   }
}

//+------------------------------------------------------------------+
//| Evaluasi Sinyal Anatomi Tabranij + Buat Komentar Alasan Order    |
//+------------------------------------------------------------------+
void EvaluateTabranijSignal(const Tabranij &t1, const Tabranij &t2,
                            bool &out_buy, bool &out_sell,
                            bool &out_is_break_or_rev,
                            string &out_order_comment, string &out_reason)
{
   out_buy             = false;
   out_sell            = false;
   out_is_break_or_rev = false;
   out_order_comment   = "";
   out_reason          = "Tidak Ada Sinyal";

   if(t1.Waktu == 0)
   {
      out_reason = "Menunggu Data Bar Timeframe...";
      return;
   }

   if(InpMinNetoPoints > 0 && (t1.N / _Point) < InpMinNetoPoints)
   {
      out_reason = StringFormat("Neto Kecil (%.0f < %.0f pts)", t1.N / _Point, InpMinNetoPoints);
      return;
   }

   double min_eff = InpMinEfficiencyRatio / 100.0;
   double min_rej = InpMinRejectionRatio  / 100.0;

   double neto_pct = t1.EfisiensiNeto       * 100.0;
   double eka_pct  = t1.RasioPenolakanAtas  * 100.0; // eka = Ekor Atas %
   double ekb_pct  = t1.RasioPenolakanBawah * 100.0; // ekb = Ekor Bawah %

   ENUM_TIMEFRAMES exec_tf = GetExecTF();
   double prev_highest_T = (t2.T > 0.0) ? t2.T : t1.T;
   double prev_lowest_R  = (t2.R > 0.0) ? t2.R : t1.R;
   GetExtremeTR(_Symbol, exec_tf, 2, MathMax(1, InpLookbackBars), prev_highest_T, prev_lowest_R);

   // A. Sinyal Momentum Neto
   bool sig_momentum_buy  = (t1.IsNaik  && t1.EfisiensiNeto >= min_eff);
   bool sig_momentum_sell = (!t1.IsNaik && t1.EfisiensiNeto >= min_eff);

   // B. Sinyal Ekor Atas (eka) & Ekor Bawah (ekb) (Dominan atau >= Rasio Ekor)
   bool is_eka_dominant   = (t1.EkorAtas  > t1.EkorBawah && (t1.RasioPenolakanAtas  >= min_rej || t1.EkorAtas  > t1.N));
   bool is_ekb_dominant   = (t1.EkorBawah > t1.EkorAtas  && (t1.RasioPenolakanBawah >= min_rej || t1.EkorBawah > t1.N));

   bool sig_ekor_buy  = false;
   bool sig_ekor_sell = false;
   string ekor_buy_comment  = "";
   string ekor_sell_comment = "";

   if(InpEkorDirection == EKOR_EKA_BUY_EKB_SELL)
   {
      if(is_eka_dominant)
      {
         sig_ekor_buy     = true;
         ekor_buy_comment = StringFormat("GT Buy A %.0f%%", eka_pct);
      }
      if(is_ekb_dominant)
      {
         sig_ekor_sell     = true;
         ekor_sell_comment = StringFormat("GT Sell B %.0f%%", ekb_pct);
      }
   }
   else
   {
      if(is_ekb_dominant)
      {
         sig_ekor_buy     = true;
         ekor_buy_comment = StringFormat("GT Buy B %.0f%%", ekb_pct);
      }
      if(is_eka_dominant)
      {
         sig_ekor_sell     = true;
         ekor_sell_comment = StringFormat("GT Sell A %.0f%%", eka_pct);
      }
   }

   // C. Sinyal Breakout Tabranij (Inti Tembus T/R Sebelumnya)
   bool sig_breakout_buy  = (t1.IsNaik  && (t1.I > prev_highest_T || (t2.T > 0 && t1.I > t2.T)));
   bool sig_breakout_sell = (!t1.IsNaik && (t1.I < prev_lowest_R  || (t2.R > 0 && t1.I < t2.R)));

   // D. Sinyal Reversal Tabranij (Sweep T/R atau Engulfing Badan A/B)
   bool rev_sweep_buy     = (t1.R < prev_lowest_R  && t1.I > prev_lowest_R  && t1.RasioPenolakanBawah >= min_rej);
   bool rev_sweep_sell    = (t1.T > prev_highest_T && t1.I < prev_highest_T && t1.RasioPenolakanAtas  >= min_rej);

   bool rev_engulf_buy    = (t2.Waktu > 0 && !t2.IsNaik && t1.IsNaik  && t1.I > t2.AtapBadan   && t1.N > t2.N);
   bool rev_engulf_sell   = (t2.Waktu > 0 && t2.IsNaik  && !t1.IsNaik && t1.I < t2.LantaiBadan && t1.N > t2.N);

   bool sig_reversal_buy  = (rev_sweep_buy  || rev_engulf_buy);
   bool sig_reversal_sell = (rev_sweep_sell || rev_engulf_sell);

   switch(InpEntryMode)
   {
      case MODE_FOLLOW_TREND:
         out_buy  = t1.IsNaik;
         out_sell = !t1.IsNaik;
         if(out_buy)
         {
            out_order_comment = StringFormat("GT Buy neto %.0f%%", neto_pct);
            out_reason        = out_order_comment;
         }
         else
         {
            out_order_comment = StringFormat("GT Sell neto %.0f%%", neto_pct);
            out_reason        = out_order_comment;
         }
         break;

      case MODE_COUNTER_TREND:
         out_buy  = !t1.IsNaik;
         out_sell = t1.IsNaik;
         if(out_buy)
         {
            out_order_comment = StringFormat("GT Buy neto %.0f%%", neto_pct);
            out_reason        = out_order_comment + " (Counter)";
         }
         else
         {
            out_order_comment = StringFormat("GT Sell neto %.0f%%", neto_pct);
            out_reason        = out_order_comment + " (Counter)";
         }
         break;

      case MODE_REJECTION_EKOR:
         out_buy  = sig_ekor_buy;
         out_sell = sig_ekor_sell;
         if(out_buy)
         {
            out_order_comment = ekor_buy_comment;
            out_reason        = out_order_comment;
         }
         else if(out_sell)
         {
            out_order_comment = ekor_sell_comment;
            out_reason        = out_order_comment;
         }
         else
            out_reason = StringFormat("Skip: A %.0f%% | B %.0f%%", eka_pct, ekb_pct);
         break;

      case MODE_BREAKOUT:
         out_buy             = sig_breakout_buy;
         out_sell            = sig_breakout_sell;
         out_is_break_or_rev = (out_buy || out_sell);
         if(out_buy)
         {
            out_order_comment = "GT Buy breakout";
            out_reason        = StringFormat("GT Buy breakout (T > %.2f | neto %.0f%%)", prev_highest_T, neto_pct);
         }
         else if(out_sell)
         {
            out_order_comment = "GT Sell breakout";
            out_reason        = StringFormat("GT Sell breakout (R < %.2f | neto %.0f%%)", prev_lowest_R, neto_pct);
         }
         else
            out_reason = "Skip: Belum Ada Breakout T/R";
         break;

      case MODE_REVERSAL:
         out_buy             = sig_reversal_buy;
         out_sell            = sig_reversal_sell;
         out_is_break_or_rev = (out_buy || out_sell);
         if(out_buy)
         {
            out_order_comment = "GT Buy reversal";
            out_reason        = rev_sweep_buy
                                ? StringFormat("GT Buy reversal (Sweep R | B %.0f%%)", ekb_pct)
                                : StringFormat("GT Buy reversal (Engulf A | neto %.0f%%)", neto_pct);
         }
         else if(out_sell)
         {
            out_order_comment = "GT Sell reversal";
            out_reason        = rev_sweep_sell
                                ? StringFormat("GT Sell reversal (Sweep T | A %.0f%%)", eka_pct)
                                : StringFormat("GT Sell reversal (Engulf B | neto %.0f%%)", neto_pct);
         }
         else
            out_reason = "Skip: Belum Ada Reversal Tabranij";
         break;

      case MODE_SMART_HYBRID:
         // 1. Breakout T/R
         if(sig_breakout_buy)
         {
            out_buy             = true;
            out_is_break_or_rev = true;
            out_order_comment   = "GT Buy breakout";
            out_reason          = StringFormat("GT Buy breakout (neto %.0f%%)", neto_pct);
         }
         else if(sig_breakout_sell)
         {
            out_sell            = true;
            out_is_break_or_rev = true;
            out_order_comment   = "GT Sell breakout";
            out_reason          = StringFormat("GT Sell breakout (neto %.0f%%)", neto_pct);
         }
         // 2. Reversal Sweep / Engulfing
         else if(sig_reversal_buy)
         {
            out_buy             = true;
            out_is_break_or_rev = true;
            out_order_comment   = "GT Buy reversal";
            out_reason          = StringFormat("GT Buy reversal (%s)", (rev_sweep_buy ? "Sweep R" : "Engulf A"));
         }
         else if(sig_reversal_sell)
         {
            out_sell            = true;
            out_is_break_or_rev = true;
            out_order_comment   = "GT Sell reversal";
            out_reason          = StringFormat("GT Sell reversal (%s)", (rev_sweep_sell ? "Sweep T" : "Engulf B"));
         }
         // 3. Ekor Dominan (eka / ekb)
         else if(sig_ekor_buy)
         {
            out_buy           = true;
            out_order_comment = ekor_buy_comment;
            out_reason        = out_order_comment;
         }
         else if(sig_ekor_sell)
         {
            out_sell          = true;
            out_order_comment = ekor_sell_comment;
            out_reason        = out_order_comment;
         }
         // 4. Neto Dominan (Selalu Aktif Tanpa Dead-Zone)
         else if(t1.IsNaik)
         {
            out_buy           = true;
            out_order_comment = StringFormat("GT Buy neto %.0f%%", neto_pct);
            out_reason        = out_order_comment;
         }
         else
         {
            out_sell          = true;
            out_order_comment = StringFormat("GT Sell neto %.0f%%", neto_pct);
            out_reason        = out_order_comment;
         }
         break;
   }
}

//+------------------------------------------------------------------+
//| Hapus Semua Objek Garis & Label dari Chart                       |
//+------------------------------------------------------------------+
void DeleteChartLines()
{
   ObjectDelete(0, LINE_EXP_BUY_NAME);
   ObjectDelete(0, LINE_EXP_SELL_NAME);
   ObjectDelete(0, LINE_BEP_NAME);
   ObjectDelete(0, LINE_TP_NAME);
   ObjectDelete(0, LINE_SL_NAME);
   ObjectDelete(0, LINE_SO_NAME);

   ObjectDelete(0, LABEL_EXP_BUY_NAME);
   ObjectDelete(0, LABEL_EXP_SELL_NAME);
   ObjectDelete(0, LABEL_BEP_NAME);
   ObjectDelete(0, LABEL_TP_NAME);
   ObjectDelete(0, LABEL_SL_NAME);
   ObjectDelete(0, LABEL_SO_NAME);
}

//+------------------------------------------------------------------+
//| Buat atau Perbarui Garis Horizontal + Label di Chart             |
//+------------------------------------------------------------------+
void DrawOrUpdateHorizontalLine(string line_name, string label_name, double price, color line_color,
                                ENUM_LINE_STYLE style, int width, string description)
{
   if(price <= 0 || !MathIsValidNumber(price))
   {
      ObjectDelete(0, line_name);
      ObjectDelete(0, label_name);
      return;
   }

   double normalized_price = NormalizeDouble(price, _Digits);

   if(ObjectFind(0, line_name) < 0)
   {
      ObjectCreate(0, line_name, OBJ_HLINE, 0, 0, normalized_price);
      ObjectSetInteger(0, line_name, OBJPROP_BACK, false);
      ObjectSetInteger(0, line_name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, line_name, OBJPROP_SELECTED, false);
   }
   ObjectSetDouble(0, line_name, OBJPROP_PRICE, normalized_price);
   ObjectSetInteger(0, line_name, OBJPROP_COLOR, line_color);
   ObjectSetInteger(0, line_name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, line_name, OBJPROP_WIDTH, width);
   ObjectSetString(0, line_name, OBJPROP_TEXT, description);
   ObjectSetString(0, line_name, OBJPROP_TOOLTIP, description);

   if(InpShowLineLabels)
   {
      datetime bar_time = iTime(_Symbol, _Period, 0);
      if(bar_time > 0)
      {
         if(ObjectFind(0, label_name) < 0)
         {
            ObjectCreate(0, label_name, OBJ_TEXT, 0, bar_time, normalized_price);
            ObjectSetInteger(0, label_name, OBJPROP_ANCHOR, ANCHOR_RIGHT_LOWER);
            ObjectSetString(0, label_name, OBJPROP_FONT, "Consolas");
            ObjectSetInteger(0, label_name, OBJPROP_FONTSIZE, 9);
            ObjectSetInteger(0, label_name, OBJPROP_SELECTABLE, false);
         }
         ObjectMove(0, label_name, 0, bar_time, normalized_price);
         ObjectSetInteger(0, label_name, OBJPROP_COLOR, line_color);
         ObjectSetString(0, label_name, OBJPROP_TEXT, "  " + description + "  ");
      }
   }
   else
   {
      ObjectDelete(0, label_name);
   }
}

//+------------------------------------------------------------------+
//| Hitung Target Profit, Batas Rugi (SL), & Jarak Stop Out (SO)     |
//+------------------------------------------------------------------+
void CalculateTargets(double total_profit, double &target_tp_money, double &max_loss_money,
                      double &remaining_to_so_money, double &total_loss_at_so_money)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   if(InpTPType == BASKET_USD)
      target_tp_money = InpTargetUSD;
   else
      target_tp_money = balance * (InpTargetPercent / 100.0);

   if(InpSLType == BASKET_USD)
      max_loss_money = InpMaxLossUSD;
   else
      max_loss_money = balance * (InpMaxLossPercent / 100.0);

   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double margin   = AccountInfoDouble(ACCOUNT_MARGIN);
   double so_level = AccountInfoDouble(ACCOUNT_MARGIN_SO_SO);
   long   so_mode  = AccountInfoInteger(ACCOUNT_MARGIN_SO_MODE);

   double min_equity_so = 0.0;
   if(so_mode == ACCOUNT_STOPOUT_MODE_PERCENT)
      min_equity_so = margin * (so_level / 100.0);
   else
      min_equity_so = so_level;

   remaining_to_so_money  = MathMax(0.0, equity - min_equity_so);
   total_loss_at_so_money = remaining_to_so_money - total_profit;
}

//+------------------------------------------------------------------+
//| Hitung & Gambar 6 Garis: Exposure BUY, Exposure SELL, BEP, TP,   |
//| Batas Rugi (SL), dan Stop Out (SO)                               |
//+------------------------------------------------------------------+
void UpdateChartLines(const BasketExposure &exp,
                      double target_tp_money, double max_loss_money,
                      double remaining_to_so_money, double total_loss_at_so_money,
                      double &out_exp_buy_price, double &out_exp_sell_price,
                      double &out_bep_price, double &out_tp_price,
                      double &out_sl_price, double &out_so_price)
{
   out_exp_buy_price  = 0.0;
   out_exp_sell_price = 0.0;
   out_bep_price      = 0.0;
   out_tp_price       = 0.0;
   out_sl_price       = 0.0;
   out_so_price       = 0.0;

   double tick_value  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double current_bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(tick_size <= 0.0 || tick_value <= 0.0 || current_bid <= 0.0)
   {
      DeleteChartLines();
      return;
   }

   double value_per_price_unit = tick_value / tick_size;

   if(exp.buy_count > 0 && exp.buy_lots > 0.0)
   {
      double buy_usd_per_unit = exp.buy_lots * value_per_price_unit;
      out_exp_buy_price = current_bid + ((0.0 - exp.buy_profit) / buy_usd_per_unit);
   }

   if(exp.sell_count > 0 && exp.sell_lots > 0.0)
   {
      double sell_usd_per_unit = -exp.sell_lots * value_per_price_unit;
      out_exp_sell_price = current_bid + ((0.0 - exp.sell_profit) / sell_usd_per_unit);
   }

   if(MathAbs(exp.net_lots) >= 0.00001)
   {
      double basket_usd_per_unit = exp.net_lots * value_per_price_unit;

      out_bep_price = current_bid + ((0.0 - exp.total_profit) / basket_usd_per_unit);
      out_tp_price  = current_bid + ((target_tp_money - exp.total_profit) / basket_usd_per_unit);
      out_sl_price  = current_bid + (((-max_loss_money) - exp.total_profit) / basket_usd_per_unit);
      out_so_price  = current_bid + ((-remaining_to_so_money) / basket_usd_per_unit);
   }

   if(!InpShowChartLines || (MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE)))
      return;

   if(InpShowExposureLines)
   {
      if(out_exp_buy_price > 0.0)
      {
         string exp_buy_desc = StringFormat("[EXPOSURE BUY: %d Pos | %.2f Lot | $%.2f | Auto-Overtake: Sell %.2f Lot] @ %." + IntegerToString(_Digits) + "f",
                                            exp.buy_count, exp.buy_lots, exp.buy_profit, (exp.buy_lots * InpOvertakeLotFactor), out_exp_buy_price);
         DrawOrUpdateHorizontalLine(LINE_EXP_BUY_NAME, LABEL_EXP_BUY_NAME, out_exp_buy_price, InpColorExpBuy, STYLE_DASH, 1, exp_buy_desc);
      }
      else
      {
         ObjectDelete(0, LINE_EXP_BUY_NAME);
         ObjectDelete(0, LABEL_EXP_BUY_NAME);
      }

      if(out_exp_sell_price > 0.0)
      {
         string exp_sell_desc = StringFormat("[EXPOSURE SELL: %d Pos | %.2f Lot | $%.2f | Auto-Overtake: Buy %.2f Lot] @ %." + IntegerToString(_Digits) + "f",
                                             exp.sell_count, exp.sell_lots, exp.sell_profit, (exp.sell_lots * InpOvertakeLotFactor), out_exp_sell_price);
         DrawOrUpdateHorizontalLine(LINE_EXP_SELL_NAME, LABEL_EXP_SELL_NAME, out_exp_sell_price, InpColorExpSell, STYLE_DASH, 1, exp_sell_desc);
      }
      else
      {
         ObjectDelete(0, LINE_EXP_SELL_NAME);
         ObjectDelete(0, LABEL_EXP_SELL_NAME);
      }
   }
   else
   {
      ObjectDelete(0, LINE_EXP_BUY_NAME);
      ObjectDelete(0, LABEL_EXP_BUY_NAME);
      ObjectDelete(0, LINE_EXP_SELL_NAME);
      ObjectDelete(0, LABEL_EXP_SELL_NAME);
   }

   if(MathAbs(exp.net_lots) >= 0.00001)
   {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double tp_pct  = (balance > 0) ? (target_tp_money / balance * 100.0) : 0.0;
      double sl_pct  = (balance > 0) ? (max_loss_money / balance * 100.0) : 0.0;
      double so_pct  = (balance > 0) ? (total_loss_at_so_money / balance * 100.0) : 0.0;
      double so_lvl  = AccountInfoDouble(ACCOUNT_MARGIN_SO_SO);

      string dir_label = (exp.net_lots > 0)
                         ? StringFormat("NET BUY %.2f Lot", exp.net_lots)
                         : StringFormat("NET SELL %.2f Lot", MathAbs(exp.net_lots));

      string bep_desc = StringFormat("[BEP $0.00] %s @ %." + IntegerToString(_Digits) + "f",
                                     dir_label, out_bep_price);
      string tp_desc  = StringFormat("[TARGET TP +$%.2f (+%.2f%%)] @ %." + IntegerToString(_Digits) + "f",
                                     target_tp_money, tp_pct, out_tp_price);
      string sl_desc  = StringFormat("[BATAS RUGI (SL)%s -$%.2f (-%.2f%%)] @ %." + IntegerToString(_Digits) + "f",
                                     (InpUseBasketSL ? "" : " NON-AKTIF"), max_loss_money, sl_pct, out_sl_price);
      string so_desc  = StringFormat("[STOP OUT (SO %.0f%%) -$%.2f (-%.2f%%)] @ %." + IntegerToString(_Digits) + "f",
                                     so_lvl, total_loss_at_so_money, so_pct, out_so_price);

      DrawOrUpdateHorizontalLine(LINE_BEP_NAME, LABEL_BEP_NAME, out_bep_price, InpColorBEP, InpLineStyle, InpLineWidth, bep_desc);
      DrawOrUpdateHorizontalLine(LINE_TP_NAME,  LABEL_TP_NAME,  out_tp_price,  InpColorTP,  InpLineStyle, InpLineWidth, tp_desc);
      DrawOrUpdateHorizontalLine(LINE_SL_NAME,  LABEL_SL_NAME,  out_sl_price,  InpColorSL,  InpLineStyle, InpLineWidth, sl_desc);

      if(InpShowSOLine)
         DrawOrUpdateHorizontalLine(LINE_SO_NAME, LABEL_SO_NAME, out_so_price, InpColorSO, STYLE_DOT, 1, so_desc);
      else
      {
         ObjectDelete(0, LINE_SO_NAME);
         ObjectDelete(0, LABEL_SO_NAME);
      }
   }
   else
   {
      ObjectDelete(0, LINE_BEP_NAME);
      ObjectDelete(0, LABEL_BEP_NAME);
      ObjectDelete(0, LINE_TP_NAME);
      ObjectDelete(0, LABEL_TP_NAME);
      ObjectDelete(0, LINE_SL_NAME);
      ObjectDelete(0, LABEL_SL_NAME);
      ObjectDelete(0, LINE_SO_NAME);
      ObjectDelete(0, LABEL_SO_NAME);
   }

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Tutup Posisi Keranjang (0 = Semua, 1 = Hanya BUY, -1 = Hanya SELL)|
//+------------------------------------------------------------------+
void ClosePositionsBySide(int side_filter)
{
   int max_attempts = 5;

   for(int attempt = 1; attempt <= max_attempts; attempt++)
   {
      int still_open = 0;

      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket > 0 && IsPositionEligible(ticket))
         {
            long type = PositionGetInteger(POSITION_TYPE);
            if(side_filter == 1  && type != POSITION_TYPE_BUY)  continue;
            if(side_filter == -1 && type != POSITION_TYPE_SELL) continue;

            long magic = PositionGetInteger(POSITION_MAGIC);

            if(trade.PositionClose(ticket))
            {
               Print("[CloseBasket] Berhasil menutup tiket #", ticket, " (Magic: ", magic, ")");
            }
            else
            {
               Print("[CloseBasket] Percobaan ", attempt, " Gagal tiket #", ticket,
                     " - Retcode: ", trade.ResultRetcode(), " (", trade.ResultRetcodeDescription(), ")");
               still_open++;
            }
         }
      }

      if(still_open == 0)
      {
         Print("[CloseBasket] POSISI TARGET TELAH BERSIH TERTUTUP!");
         break;
      }

      Sleep(150);
   }

   if(side_filter == 0)
      DeleteAllPendingOrders();

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Monitor & Eksekusi Basket TP & SL + Exposure (Real-Time)         |
//+------------------------------------------------------------------+
void ManageBasketProfitAndLoss(const Tabranij &t, BasketExposure &exp)
{
   CollectBasketExposure(exp);

   double target_tp_money        = 0.0;
   double max_loss_money         = 0.0;
   double remaining_to_so_money  = 0.0;
   double total_loss_at_so_money = 0.0;

   CalculateTargets(exp.total_profit, target_tp_money, max_loss_money, remaining_to_so_money, total_loss_at_so_money);

   double exp_buy_price  = 0.0;
   double exp_sell_price = 0.0;
   double bep_price      = 0.0;
   double tp_price       = 0.0;
   double sl_price       = 0.0;
   double so_price       = 0.0;

   if(exp.total_count > 0)
   {
      UpdateChartLines(exp, target_tp_money, max_loss_money,
                       remaining_to_so_money, total_loss_at_so_money,
                       exp_buy_price, exp_sell_price,
                       bep_price, tp_price, sl_price, so_price);
   }
   else
   {
      DeleteChartLines();
   }

   double balance     = AccountInfoDouble(ACCOUNT_BALANCE);
   double current_pct = (balance > 0) ? (exp.total_profit / balance * 100.0) : 0.0;
   double tp_pct      = (balance > 0) ? (target_tp_money / balance * 100.0) : 0.0;
   double sl_pct      = (balance > 0) ? (max_loss_money / balance * 100.0) : 0.0;
   double so_pct      = (balance > 0) ? (total_loss_at_so_money / balance * 100.0) : 0.0;

   string micro_status = InpEnable10SecCycle ? StringFormat("AKTIF (Up: %d | Dn: %d) | %s", g_last_eval_up_ticks, g_last_eval_down_ticks, g_last_signal_info) : "NON-AKTIF (Bar M1 Mode)";
   string status_text = StringFormat(
      "=== [GRAFIK TABRANIJ MONITOR v3.20 (10s MIKRO)] ===\n" +
      "Mikro 10s      : %s\n" +
      "Rangkaian Waktu: %s\n" +
      "Kotak Kedepan  : %s\n" +
      "Kompas MTF     : %s\n" +
      "Sinyal & Entri : %s | Last: [%s]\n" +
      "--------------------------------------\n" +
      "T (Tinggi): %.2f | R (Rendah): %.2f | N (Neto): %.2f | J (Julat): %.2f\n" +
      "Atas (A): %.0f%% | Neto (N): %.0f%% | Bawah (B): %.0f%% (A+N+B=100%%)\n" +
      "--------------------------------------\n" +
      "EXPOSURE BUY   : %d Pos | %.2f Lot | P/L: $%.2f | Garis: %s\n" +
      "EXPOSURE SELL  : %d Pos | %.2f Lot | P/L: $%.2f | Garis: %s\n" +
      "TOTAL KERANJANG: %d Pos (Pending: %d) | Net: %.2f Lot | Floating: $%.2f (%.2f%%)\n" +
      "--------------------------------------\n" +
      "1. Garis BEP ($0)    : %s\n" +
      "2. Garis Target TP   : %s (+$%.2f / +%.2f%%)\n" +
      "3. Garis Batas Rugi  : %s (-$%.2f / -%.2f%%) [%s]\n" +
      "4. Garis Stop Out SO : %s (-$%.2f / -%.2f%%)\n",
      micro_status,
      g_timeline_info,
      g_future_boxes_info,
      g_mtf_status_info,
      g_last_signal_info, g_last_order_comment,
      t.T, t.R, t.N, t.J,
      (t.EfisiensiNeto * 100.0), (t.RasioPenolakanAtas * 100.0), (t.RasioPenolakanBawah * 100.0),
      exp.buy_count,  exp.buy_lots,  exp.buy_profit,  (exp_buy_price  > 0 ? DoubleToString(exp_buy_price,  _Digits) : "-"),
      exp.sell_count, exp.sell_lots, exp.sell_profit, (exp_sell_price > 0 ? DoubleToString(exp_sell_price, _Digits) : "-"),
      exp.total_count, exp.pending_count, exp.net_lots, exp.total_profit, current_pct,
      (exp.total_count == 0 ? "-" : (bep_price > 0 ? DoubleToString(bep_price, _Digits) : "TERKUNCI (HEDGE)")),
      (exp.total_count == 0 ? "-" : (tp_price  > 0 ? DoubleToString(tp_price,  _Digits) : "TERKUNCI (HEDGE)")), target_tp_money, tp_pct,
      (exp.total_count == 0 ? "-" : (sl_price  > 0 ? DoubleToString(sl_price,  _Digits) : "TERKUNCI (HEDGE)")), max_loss_money,  sl_pct, (InpUseBasketSL ? "AKTIF" : "NON-AKTIF"),
      (exp.total_count == 0 ? "-" : (so_price  > 0 ? DoubleToString(so_price,  _Digits) : "TERKUNCI (HEDGE)")), total_loss_at_so_money, so_pct
   );
   Comment(status_text);

   if(exp.total_count == 0) return;

   // --- MODE PISAH KERANJANG BUY & SELL SENDIRI-SENDIRI ---
   if(InpBasketDirection == BASKET_SEPARATE_BUY_SELL)
   {
      if(exp.buy_count > 0 && exp.buy_profit >= target_tp_money)
      {
         Print(">>> [KERANJANG BUY TP TERCAPAI!] Profit BUY: $", DoubleToString(exp.buy_profit, 2));
         ClosePositionsBySide(1);
         if(InpEnableSound && !MQLInfoInteger(MQL_TESTER)) PlaySound(InpSoundTP);
         return;
      }
      if(exp.sell_count > 0 && exp.sell_profit >= target_tp_money)
      {
         Print(">>> [KERANJANG SELL TP TERCAPAI!] Profit SELL: $", DoubleToString(exp.sell_profit, 2));
         ClosePositionsBySide(-1);
         if(InpEnableSound && !MQLInfoInteger(MQL_TESTER)) PlaySound(InpSoundTP);
         return;
      }
      if(InpUseBasketSL && exp.buy_count > 0 && exp.buy_profit <= -max_loss_money)
      {
         Print(">>> [KERANJANG BUY SL TERSENTUH!] Rugi BUY: $", DoubleToString(exp.buy_profit, 2));
         ClosePositionsBySide(1);
         if(InpEnableSound && !MQLInfoInteger(MQL_TESTER)) PlaySound(InpSoundSL);
         return;
      }
      if(InpUseBasketSL && exp.sell_count > 0 && exp.sell_profit <= -max_loss_money)
      {
         Print(">>> [KERANJANG SELL SL TERSENTUH!] Rugi SELL: $", DoubleToString(exp.sell_profit, 2));
         ClosePositionsBySide(-1);
         if(InpEnableSound && !MQLInfoInteger(MQL_TESTER)) PlaySound(InpSoundSL);
         return;
      }
      return;
   }

   // --- MODE KERANJANG GABUNGAN (ONE-WAY ATAU MIXED ANTI-LOCK) ---
   if(exp.total_profit >= target_tp_money)
   {
      Print("======================================================");
      Print(">>> [BASKET TP TERCAPAI!] Profit: $", DoubleToString(exp.total_profit, 2),
            " >= Target: $", DoubleToString(target_tp_money, 2));
      Print(">>> Eksekusi Sapu Bersih seluruh ", exp.total_count, " posisi & pending order...");
      Print("======================================================");

      ClosePositionsBySide(0);
      DeleteChartLines();

      if(InpEnableSound && !MQLInfoInteger(MQL_TESTER)) PlaySound(InpSoundTP);
      return;
   }

   if(InpUseBasketSL && exp.total_profit <= -max_loss_money)
   {
      Print("======================================================");
      Print(">>> [BATAS RUGI / BASKET SL TERSENTUH!] Rugi: $", DoubleToString(exp.total_profit, 2),
            " <= Batas: -$", DoubleToString(max_loss_money, 2));
      Print(">>> CUT LOSS DARURAT: Sapu bersih seluruh posisi & pending order!");
      Print("======================================================");

      ClosePositionsBySide(0);
      DeleteChartLines();

      if(InpEnableSound && !MQLInfoInteger(MQL_TESTER)) PlaySound(InpSoundSL);
      return;
   }
}

//+------------------------------------------------------------------+
//| Evaluasi Pemicu Mikro 10 Detik (Opsi 1, 2, 3)                     |
//+------------------------------------------------------------------+
bool Check10SecMicroTrigger(bool &out_buy, bool &out_sell, bool &out_is_booster,
                            string &out_order_comment, string &out_signal_info)
{
   out_buy           = false;
   out_sell          = false;
   out_is_booster    = false;
   out_order_comment = "";
   out_signal_info   = "Standby 10s Window";

   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);

   // Slot window berbasis kelipatan 10 detik (misal detik 0-9, 10-19, dst.)
   long current_window_key = (long)(now / 10);

   if(g_last_10s_window_key < 0)
   {
      g_last_10s_window_key = current_window_key;
      return false;
   }

   // Hanya evaluasi tepat di detik pergantian slot 10 detik (10, 20, 30, 40, 50, 00)
   if(current_window_key == g_last_10s_window_key)
   {
      return false;
   }

   // Catat akumulasi tick dari 10 detik yang baru saja selesai
   int up_ticks   = g_window_up_ticks;
   int down_ticks = g_window_down_ticks;

   g_last_eval_up_ticks   = up_ticks;
   g_last_eval_down_ticks = down_ticks;

   // Reset penghitung tick untuk jendela 10 detik berikutnya
   g_window_up_ticks     = 0;
   g_window_down_ticks   = 0;
   g_last_10s_window_key = current_window_key;

   // Jika pasar membeku (0 tick bergerak), tahan
   if(up_ticks == 0 && down_ticks == 0)
   {
      out_signal_info = "10s Hold: Pasar Datar (0 Tick)";
      return false;
   }

   // Ambil Anatomi Kotak GT M1 Bar 1 (Tutup) dan Bar 0 (Live)
   Tabranij t1 = HitungTabranij(_Symbol, PERIOD_M1, 1);
   Tabranij t0 = HitungTabranij(_Symbol, PERIOD_M1, 0);
   if(t1.Waktu == 0 || t0.Waktu == 0)
   {
      out_signal_info = "Menunggu Data Bar M1...";
      return false;
   }

   double current_bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Ambil Ekstrem 6 Kotak M1 ke Belakang (T6 = Highest High, R6 = Lowest Low)
   double highest_T6 = 0.0;
   double lowest_R6  = 0.0;
   GetExtremeTR(_Symbol, PERIOD_M1, 1, MathMax(1, InpLookback6Boxes), highest_T6, lowest_R6);

   // =================================================================
   // TINGKAT 2: OPSI 3 - MELAMPAUI 6 KOTAK M1 (BOOSTER LOT)
   // =================================================================
   // 3A. BREAKOUT 6 KOTAK M1
   if(highest_T6 > 0.0 && current_bid > highest_T6 && up_ticks > down_ticks)
   {
      out_buy           = true;
      out_is_booster    = true;
      out_order_comment = StringFormat("GT Buy 10s Breakout T6 (Up %d vs Dn %d)", up_ticks, down_ticks);
      out_signal_info   = StringFormat("BOOSTER: Breakout T6 M1 (+%d UpTicks)", up_ticks - down_ticks);
      return true;
   }
   if(lowest_R6 > 0.0 && current_bid < lowest_R6 && down_ticks > up_ticks)
   {
      out_sell          = true;
      out_is_booster    = true;
      out_order_comment = StringFormat("GT Sell 10s Breakout R6 (Dn %d vs Up %d)", down_ticks, up_ticks);
      out_signal_info   = StringFormat("BOOSTER: Breakout R6 M1 (+%d DnTicks)", down_ticks - up_ticks);
      return true;
   }

   // 3B. REVERSAL / LIQUIDITY SWEEP 6 KOTAK (Menusuk di luar lalu ditarik mundur)
   if(highest_T6 > 0.0 && t0.T > highest_T6 && current_bid < highest_T6 && down_ticks > up_ticks)
   {
      out_sell          = true;
      out_is_booster    = true;
      out_order_comment = StringFormat("GT Sell 10s Sweep T6 Rev (Dn %d vs Up %d)", down_ticks, up_ticks);
      out_signal_info   = StringFormat("BOOSTER: Reversal Sweep T6 M1 (+%d DnTicks)", down_ticks - up_ticks);
      return true;
   }
   if(lowest_R6 > 0.0 && t0.R < lowest_R6 && current_bid > lowest_R6 && up_ticks > down_ticks)
   {
      out_buy           = true;
      out_is_booster    = true;
      out_order_comment = StringFormat("GT Buy 10s Sweep R6 Rev (Up %d vs Dn %d)", up_ticks, down_ticks);
      out_signal_info   = StringFormat("BOOSTER: Reversal Sweep R6 M1 (+%d UpTicks)", up_ticks - down_ticks);
      return true;
   }

   // =================================================================
   // TINGKAT 1: REGULER (DI DALAM RANGE 6 KOTAK M1 - LOT STANDAR)
   // =================================================================

   // OPSI 2: PANTULAN EKOR DOMINAN M1 (REJECTION ATAS A / BAWAH B)
   if(InpEnableRejectionM1)
   {
      // Pantulan Lantai Bawah (B)
      if(t1.B > t1.A && (t1.RasioPenolakanBawah >= 0.35 || t1.B > t1.N))
      {
         if(current_bid <= (t1.LantaiBadan + (t1.J * 0.25)) && up_ticks > down_ticks)
         {
            out_buy           = true;
            out_is_booster    = false;
            out_order_comment = StringFormat("GT Buy 10s Rejection B (Up %d vs Dn %d)", up_ticks, down_ticks);
            out_signal_info   = StringFormat("REGULER: Pantulan Bawah (B) M1 (Up %d vs Dn %d)", up_ticks, down_ticks);
            return true;
         }
      }
      // Pantulan Atap Atas (A)
      if(t1.A > t1.B && (t1.RasioPenolakanAtas >= 0.35 || t1.A > t1.N))
      {
         if(current_bid >= (t1.AtapBadan - (t1.J * 0.25)) && down_ticks > up_ticks)
         {
            out_sell          = true;
            out_is_booster    = false;
            out_order_comment = StringFormat("GT Sell 10s Rejection A (Dn %d vs Up %d)", down_ticks, up_ticks);
            out_signal_info   = StringFormat("REGULER: Pantulan Atas (A) M1 (Dn %d vs Up %d)", down_ticks, up_ticks);
            return true;
         }
      }
   }

   // OPSI 1: FOLLOW TREN GT M1 SEBELUMNYA (SEARAH WARNA HIJAU/MERAH)
   if(InpEnableFollowM1)
   {
      if(t1.IsNaik && up_ticks > down_ticks)
      {
         out_buy           = true;
         out_is_booster    = false;
         out_order_comment = StringFormat("GT Buy 10s Follow M1 Hijau (Up %d vs Dn %d)", up_ticks, down_ticks);
         out_signal_info   = StringFormat("REGULER: Follow M1 Hijau (Up %d vs Dn %d)", up_ticks, down_ticks);
         return true;
      }
      else if(!t1.IsNaik && down_ticks > up_ticks)
      {
         out_sell          = true;
         out_is_booster    = false;
         out_order_comment = StringFormat("GT Sell 10s Follow M1 Merah (Dn %d vs Up %d)", down_ticks, up_ticks);
         out_signal_info   = StringFormat("REGULER: Follow M1 Merah (Dn %d vs Up %d)", down_ticks, up_ticks);
         return true;
      }
   }

   out_signal_info = StringFormat("10s Netral (Up %d vs Dn %d)", up_ticks, down_ticks);
   return false;
}

//+------------------------------------------------------------------+
//| Fungsi Utama Siklus Evaluasi & Eksekusi (Dipanggil Tick & Timer) |
//+------------------------------------------------------------------+
void RunTabranijCycle(bool allow_trade_execution)
{
   ENUM_TIMEFRAMES exec_tf = GetExecTF();

   // 1. Hitung Struktur Tabranij pada TF Aktif (Bar 1 dan Bar 2, fallback ke Bar 0 jika Bar 1 belum siap)
   Tabranij t1 = HitungTabranij(_Symbol, exec_tf, 1);
   Tabranij t2 = HitungTabranij(_Symbol, exec_tf, 2);
   if(t1.Waktu == 0)
      t1 = HitungTabranij(_Symbol, exec_tf, 0);

   // 2. Hitung & Gambar Proyeksi Kotak Masa Depan (+1, +2, +3...) secara Real-Time di Semua Timeframe
   Tabranij future_boxes[];
   if(CalculateFutureProjections(future_boxes, g_timeline_info, g_future_boxes_info))
   {
      DrawFutureBoxesOnChart(future_boxes);
   }

   // 3. Evaluasi Kompas Multi-Timeframe (MTF) secara Real-Time
   bool mtf_allow_buy  = true;
   bool mtf_allow_sell = true;
   EvaluateMTFCompass(mtf_allow_buy, mtf_allow_sell, g_mtf_status_info);

   // 4. Kelola TP & SL Basket Real-Time + Gambar 6 Garis (Exposure Buy, Exposure Sell, BEP, TP, SL, SO)
   BasketExposure exp;
   ManageBasketProfitAndLoss(t1, exp);

   if(!allow_trade_execution) return;

   // 5. Batasan Maksimal Posisi Terbuka
   if(InpMaxOpenPositions > 0 && exp.total_count >= InpMaxOpenPositions)
   {
      g_last_signal_info = StringFormat("Hold: Posisi Penuh (%d/%d)", exp.total_count, InpMaxOpenPositions);
      return;
   }

   // 6. Evaluasi Sinyal Pemicu: Mode Mikro 10 Detik vs Mode Bar-by-Bar
   bool   raw_buy         = false;
   bool   raw_sell        = false;
   bool   is_break_or_rev = false;
   bool   is_booster_tier = false;
   string order_comment   = "";

   if(InpEnable10SecCycle)
   {
      if(!Check10SecMicroTrigger(raw_buy, raw_sell, is_booster_tier, order_comment, g_last_signal_info))
      {
         return;
      }
      is_break_or_rev = is_booster_tier;
   }
   else
   {
      datetime current_bar_time = iTime(_Symbol, exec_tf, 0);
      if(current_bar_time == 0 || t1.Waktu == 0) return;

      if(current_bar_time == last_exec_bar_time)
      {
         return;
      }

      EvaluateTabranijSignal(t1, t2, raw_buy, raw_sell, is_break_or_rev, order_comment, g_last_signal_info);
      if(!raw_buy && !raw_sell) return;
   }

   // 8. Saring Sinyal dengan Kompas Multi-Timeframe (MTF)
   if(raw_buy && !mtf_allow_buy)
   {
      g_last_signal_info += " [DITAHAN KOMPAS MTF SELL]";
      return;
   }
   if(raw_sell && !mtf_allow_sell)
   {
      g_last_signal_info += " [DITAHAN KOMPAS MTF BUY]";
      return;
   }

   // 9. Validasi Aturan Keranjang & Jarak Minimal Antar Posisi (Pilar 2)
   string block_reason = "";
   if(raw_buy && !CheckLayerAndStepPermission(true, is_break_or_rev, exp, block_reason))
   {
      g_last_signal_info += " [" + block_reason + "]";
      return;
   }
   if(raw_sell && !CheckLayerAndStepPermission(false, is_break_or_rev, exp, block_reason))
   {
      g_last_signal_info += " [" + block_reason + "]";
      return;
   }

   // Bersihkan pending order lama tepat sebelum memasang siklus order bar baru
   if(InpRefreshPendingEachBar)
   {
      DeleteAllPendingOrders();
   }

   bool do_market_order = (InpExecOrderType == EXEC_MARKET_ONLY ||
                           InpExecOrderType == EXEC_MARKET_AND_LIMIT ||
                           InpExecOrderType == EXEC_MARKET_AND_STOP ||
                           InpExecOrderType == EXEC_MARKET_LIMIT_STOP);

   bool executed_any = false;

   // 10. Eksekusi Market Order & Pending Order Masa Depan (+1, +2, +3)
   if(raw_buy)
   {
      double lot_to_open = CalculateNextLot(true, is_break_or_rev, exp, is_booster_tier);
      if(do_market_order)
      {
         if(SafeExecute(true, lot_to_open, order_comment))
         {
            executed_any         = true;
            g_last_order_comment = order_comment;
            Print("[GT] BUY Eksekusi ", DoubleToString(lot_to_open, 2), " Lot | Comment: [", order_comment, "]");
            if(InpEnableSound && !MQLInfoInteger(MQL_TESTER)) PlaySound(InpSoundBuy);
         }
      }
      int pend = PlaceFuturePendingOrders(true, lot_to_open, future_boxes);
      if(pend > 0) executed_any = true;
   }
   else if(raw_sell)
   {
      double lot_to_open = CalculateNextLot(false, is_break_or_rev, exp, is_booster_tier);
      if(do_market_order)
      {
         if(SafeExecute(false, lot_to_open, order_comment))
         {
            executed_any         = true;
            g_last_order_comment = order_comment;
            Print("[GT] SELL Eksekusi ", DoubleToString(lot_to_open, 2), " Lot | Comment: [", order_comment, "]");
            if(InpEnableSound && !MQLInfoInteger(MQL_TESTER)) PlaySound(InpSoundSell);
         }
      }
      int pend = PlaceFuturePendingOrders(false, lot_to_open, future_boxes);
      if(pend > 0) executed_any = true;
   }

   // Kunci waktu bar HANYA setelah order benar-benar berhasil tereksekusi (mode bar-by-bar)
   if(executed_any)
   {
      last_exec_bar_time = iTime(_Symbol, exec_tf, 0);
   }
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   InitTradeEngine();
   last_exec_bar_time = 0;

   // Bersihkan objek sisa dari timeframe sebelumnya agar koordinat ter-reset segar
   DeleteFutureBoxObjects();

   // Aktifkan Chart Shift agar ada ruang kosong di sebelah kanan candle Live untuk kotak (+1, +2, +3)
   ChartSetInteger(0, CHART_SHOW_OBJECT_DESCR, true);
   ChartSetInteger(0, CHART_SHIFT, true);
   ChartSetDouble(0, CHART_SHIFT_SIZE, 28.0);

   // Aktifkan Timer 1 Detik agar kotak bayangan & dashboard langsung muncul meski ganti TF / tick lambat
   EventSetTimer(1);

   // Jalankan siklus visualisasi pertama kali saat inisialisasi
   RunTabranijCycle(false);

   ENUM_TIMEFRAMES exec_tf = GetExecTF();
   Print(">>> [Tabranij Scalper v3.20 (10s Micro Edition)] Aktif pada ", _Symbol, " (", EnumToString(exec_tf),
         ") | Riwayat: ", InpHistoryBarsToRead, " Bar -> Proyeksi Depan: +", InpFutureBarsToProject, " Bar");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   DeleteChartLines();
   DeleteFutureBoxObjects();
   Comment("");
   Print(">>> [Tabranij Scalper] Dihentikan & objek chart dibersihkan.");
}

//+------------------------------------------------------------------+
//| Expert timer function (Update Tiap 1 Detik di Semua Timeframe)   |
//+------------------------------------------------------------------+
void OnTimer()
{
   RunTabranijCycle(true);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   double current_bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(g_last_tick_bid > 0.0)
   {
      if(current_bid > g_last_tick_bid + 0.000001)      g_window_up_ticks++;
      else if(current_bid < g_last_tick_bid - 0.000001) g_window_down_ticks++;
   }
   g_last_tick_bid = current_bid;

   RunTabranijCycle(true);
}
//+------------------------------------------------------------------+
