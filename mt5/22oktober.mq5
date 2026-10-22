//+------------------------------------------------------------------+
//|                                                    nyeserpip.mq5 |
//|           Full-margin basket EA: profit/loss % + target lines    |
//|                           Window key: 1970 (detik Unix epoch)    |
//+------------------------------------------------------------------+
#property copyright "nyeserpip"
#property version   "1.03"
#property strict

#include <Trade/Trade.mqh>

enum ENUM_NYESER_DIR
  {
   NYESER_BUY  = 0, // Buy full margin
   NYESER_SELL = 1  // Sell full margin
  };

input group "nyeserpip"
input long            InpMagic                = 1970;           // Magic / window key
input bool            InpEnableTrading        = true;           // Buka posisi otomatis
input ENUM_NYESER_DIR InpDirection            = NYESER_BUY;     // Arah full margin
input double          InpMarginUsagePercent   = 95.0;           // Pemakaian margin (%)
input int             InpSliceCount           = 5;              // Jumlah tiket (pecahan full margin)
input int             InpSliceDelaySeconds    = 1;              // Jeda antar tiket (detik)
input double          InpProfitBasketPercent  = 1.0;            // Keranjang profit (%)
input double          InpLossLimitPercent     = 1.0;            // Batas rugi (%)
input int             InpReentryDelaySeconds  = 0;              // Jeda buka ulang setelah keranjang (detik)
input int             InpMaxBasketSeconds     = 0;              // Batas waktu keranjang (0=off)
input int             InpSlippagePoints       = 30;             // Slippage (points)
input int             InpTimerSeconds         = 1;              // Refresh window (detik)
input bool            InpFitChartToLines      = true;           // Sesuaikan skala chart ke garis
input bool            InpEntryAtSecond00      = true;           // Entry hanya saat detik 00

CTrade trade;
long   g_chart = 0;

const string OBJ_KEY          = "1970";
const string OBJ_WINDOW       = "1970_window";
const string OBJ_SECONDS      = "1970_seconds";
const string OBJ_STATUS       = "1970_status";
const string OBJ_LINE_PROFIT  = "1970_line_profit";
const string OBJ_LINE_LOSS    = "1970_line_loss";
const string OBJ_LINE_SO      = "1970_line_so";

datetime g_basketStart   = 0;
datetime g_lastCloseTime = 0;
datetime g_lastSliceTime = 0;
double   g_targetLots    = 0.0;
double   g_sliceLots     = 0.0;
string   g_lastAction    = "idle";
string   g_lineInfo      = "";

//+------------------------------------------------------------------+
int OnInit()
  {
   g_chart = ChartID();
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetAsyncMode(false);
   ApplyFillingMode();
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("nyeserpip: akun netting menggabungkan tiket. Pakai akun hedging agar pecahan full margin jadi beberapa posisi.");

   EventSetTimer(MathMax(1, InpTimerSeconds));
   CreateWindow();
   UpdateTargetLines();
   UpdateWindow();
   ChartRedraw(g_chart);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectsDeleteAll(g_chart, OBJ_KEY);
   if(InpFitChartToLines)
      ChartSetInteger(g_chart, CHART_SCALEFIX, false);
   Comment("");
   ChartRedraw(g_chart);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   ManageBasket();
   MaybeOpenFullMargin();
   UpdateTargetLines();
   UpdateWindow();
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   MaybeOpenFullMargin();
   UpdateTargetLines();
   UpdateWindow();
   ChartRedraw(g_chart);
  }

//+------------------------------------------------------------------+
void ApplyFillingMode()
  {
   long filling = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((filling & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      trade.SetTypeFilling(ORDER_FILLING_IOC);
   else
      trade.SetTypeFilling(ORDER_FILLING_RETURN);
  }

//+------------------------------------------------------------------+
bool IsOurPosition(const ulong ticket)
  {
   if(!PositionSelectByTicket(ticket))
      return(false);
   if(PositionGetString(POSITION_SYMBOL) != _Symbol)
      return(false);
   if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
      return(false);
   return(true);
  }

//+------------------------------------------------------------------+
int CountOurPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && IsOurPosition(ticket))
         count++;
     }
   return(count);
  }

//+------------------------------------------------------------------+
void CollectBasket(double &profit, double &netVolume, double &vwap, datetime &oldest)
  {
   profit    = 0.0;
   netVolume = 0.0;
   vwap      = 0.0;
   oldest    = 0;
   double absVol = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurPosition(ticket))
         continue;

      double vol   = PositionGetDouble(POSITION_VOLUME);
      double price = PositionGetDouble(POSITION_PRICE_OPEN);
      long   type  = PositionGetInteger(POSITION_TYPE);
      datetime t   = (datetime)PositionGetInteger(POSITION_TIME);

      profit += PositionGetDouble(POSITION_PROFIT)
                + PositionGetDouble(POSITION_SWAP);

      double signedVol = (type == POSITION_TYPE_BUY) ? vol : -vol;
      netVolume += signedVol;
      absVol    += vol;
      vwap      += price * vol;

      if(oldest == 0 || t < oldest)
         oldest = t;
     }

   if(absVol > 0.0)
      vwap /= absVol;
  }

//+------------------------------------------------------------------+
void CloseBasket(const string reason)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurPosition(ticket))
         continue;
      trade.PositionClose(ticket);
     }
   g_lastCloseTime = TimeCurrent();
   g_basketStart   = 0;
   g_targetLots    = 0.0;
   g_sliceLots     = 0.0;
   g_lastAction    = reason;
  }

//+------------------------------------------------------------------+
void ManageBasket()
  {
   double profit = 0.0, netVol = 0.0, vwap = 0.0;
   datetime oldest = 0;
   CollectBasket(profit, netVol, vwap, oldest);

   if(CountOurPositions() == 0)
     {
      g_basketStart = 0;
      return;
     }

   if(g_basketStart == 0)
      g_basketStart = (oldest > 0 ? oldest : TimeCurrent());

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0.0)
      return;

   double profitPct = (profit / balance) * 100.0;
   int elapsed = (int)(TimeCurrent() - g_basketStart);

   if(profitPct >= InpProfitBasketPercent)
     {
      CloseBasket("keranjang profit");
      return;
     }
   if(profitPct <= -InpLossLimitPercent)
     {
      CloseBasket("batas rugi");
      return;
     }
   if(InpMaxBasketSeconds > 0 && elapsed >= InpMaxBasketSeconds)
      CloseBasket("batas detik keranjang");
  }

//+------------------------------------------------------------------+
double NormalizeVolume(double lots)
  {
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      step = 0.01;

   lots = MathFloor(lots / step) * step;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   int digits = (step >= 1.0 ? 0 : (int)MathRound(-MathLog10(step)));
   return(NormalizeDouble(lots, digits));
  }

//+------------------------------------------------------------------+
double FullMarginLots(const ENUM_ORDER_TYPE type)
  {
   double price = (type == ORDER_TYPE_BUY)
                  ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                  : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double marginOneLot = 0.0;
   if(!OrderCalcMargin(type, _Symbol, 1.0, price, marginOneLot) || marginOneLot <= 0.0)
      return(0.0);

   double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double usage = MathMax(1.0, MathMin(100.0, InpMarginUsagePercent)) / 100.0;
   return(NormalizeVolume((free * usage) / marginOneLot));
  }

//+------------------------------------------------------------------+
int ServerSeconds()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return(dt.sec);
  }

//+------------------------------------------------------------------+
int SliceCount()
  {
   return(MathMax(1, InpSliceCount));
  }

//+------------------------------------------------------------------+
double OurVolume()
  {
   double vol = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && IsOurPosition(ticket))
         vol += PositionGetDouble(POSITION_VOLUME);
     }
   return(vol);
  }

//+------------------------------------------------------------------+
bool OpenSlice(const ENUM_ORDER_TYPE type, const double lots)
  {
   bool ok = (type == ORDER_TYPE_BUY)
             ? trade.Buy(lots, _Symbol)
             : trade.Sell(lots, _Symbol);
   if(ok)
     {
      g_lastSliceTime = TimeCurrent();
      if(g_basketStart == 0)
         g_basketStart = TimeCurrent();
      g_lastAction = "tiket " + IntegerToString(CountOurPositions())
                     + "/" + IntegerToString(SliceCount())
                     + "  lot " + DoubleToString(lots, 2)
                     + "  total " + DoubleToString(OurVolume(), 2);
     }
   else
      g_lastAction = "gagal order: " + IntegerToString(trade.ResultRetcode());
   return(ok);
  }

//+------------------------------------------------------------------+
void MaybeOpenFullMargin()
  {
   if(!InpEnableTrading)
      return;

   ENUM_ORDER_TYPE type = (InpDirection == NYESER_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   int    count   = CountOurPositions();
   int    slices  = SliceCount();
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double haveVol = OurVolume();

   if(count == 0)
     {
      if(InpEntryAtSecond00 && ServerSeconds() != 0)
        {
         g_lastAction = "tunggu detik 00";
         return;
        }
      if(g_lastCloseTime > 0 && (TimeCurrent() - g_lastCloseTime) < InpReentryDelaySeconds)
         return;

      g_targetLots = FullMarginLots(type);
      g_sliceLots  = NormalizeVolume(g_targetLots / slices);
      if(g_sliceLots < minLot)
         g_sliceLots = minLot;
      if(g_targetLots <= 0.0 || g_sliceLots <= 0.0)
        {
         g_lastAction = "lot full margin = 0";
         return;
        }
      OpenSlice(type, g_sliceLots);
      return;
     }

   if(count >= slices)
      return;
   if(g_targetLots <= 0.0)
     {
      g_targetLots = NormalizeVolume(haveVol + FullMarginLots(type));
      int remain = slices - count;
      g_sliceLots = (remain > 0) ? NormalizeVolume((g_targetLots - haveVol) / remain) : minLot;
     }
   if(haveVol >= g_targetLots - (minLot * 0.5))
      return;
   if(InpSliceDelaySeconds > 0 && g_lastSliceTime > 0
      && (TimeCurrent() - g_lastSliceTime) < InpSliceDelaySeconds)
      return;
   if(InpSliceDelaySeconds <= 0 && g_lastSliceTime == TimeCurrent())
      return;

   double remaining = NormalizeVolume(g_targetLots - haveVol);
   double lots      = MathMin(g_sliceLots, remaining);
   double afford    = FullMarginLots(type);
   if(afford < minLot || lots < minLot)
      return;
   lots = NormalizeVolume(MathMin(lots, afford));
   if(lots < minLot)
      return;
   OpenSlice(type, lots);
  }

//+------------------------------------------------------------------+
bool MoneyPerPriceMove(const ENUM_ORDER_TYPE type, const double volume,
                       const double openPrice, double &mpp)
  {
   mpp = 0.0;
   if(volume <= 0.0 || openPrice <= 0.0)
      return(false);

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0)
      return(false);

   double probe = openPrice + 100.0 * point;
   if(probe <= 0.0)
      probe = openPrice * 1.001;

   double profitPlus = 0.0;
   if(!OrderCalcProfit(type, _Symbol, volume, openPrice, probe, profitPlus))
     {
      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      if(tickSize <= 0.0 || tickValue <= 0.0)
         return(false);
      mpp = (volume * tickValue) / tickSize;
      return(mpp > 0.0);
     }

   double dist = probe - openPrice;
   if(MathAbs(dist) < point * 0.1)
      return(false);

   mpp = profitPlus / dist;
   if(type == ORDER_TYPE_SELL)
      mpp = -mpp;
   return(MathAbs(mpp) > 0.0);
  }

//+------------------------------------------------------------------+
double PriceForTargetMoney(const ENUM_ORDER_TYPE type, const double volume,
                           const double markPrice, const double currentProfit,
                           const double targetMoney, const double mppAbs)
  {
   double signedMpp = (type == ORDER_TYPE_BUY) ? mppAbs : -mppAbs;
   if(MathAbs(signedMpp) < 1e-12)
      return(markPrice);
   return(markPrice + (targetMoney - currentProfit) / signedMpp);
  }

//+------------------------------------------------------------------+
double StopOutTargetMoney(const double usedMargin, const double currentProfit)
  {
   double soLevel = AccountInfoDouble(ACCOUNT_MARGIN_SO_SO);
   long   soMode  = AccountInfoInteger(ACCOUNT_MARGIN_SO_MODE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double equityFlat = equity - currentProfit;

   double equityAtSO = 0.0;
   if(soMode == ACCOUNT_STOPOUT_MODE_MONEY)
      equityAtSO = soLevel;
   else
     {
      if(usedMargin <= 0.0)
         return(0.0);
      equityAtSO = usedMargin * soLevel / 100.0;
     }
   return(equityAtSO - equityFlat);
  }

//+------------------------------------------------------------------+
bool PrepareLineModel(ENUM_ORDER_TYPE &type, double &volume, double &markPrice,
                      double &openPrice, double &profit, double &margin)
  {
   double netVol = 0.0, vwap = 0.0;
   datetime oldest = 0;
   CollectBasket(profit, netVol, vwap, oldest);

   if(CountOurPositions() > 0 && MathAbs(netVol) >= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN))
     {
      type      = (netVol > 0.0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      volume    = MathAbs(netVol);
      openPrice = (vwap > 0.0) ? vwap : markPrice;
      markPrice = (type == ORDER_TYPE_BUY)
                  ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                  : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(openPrice <= 0.0)
         openPrice = markPrice;
      margin = AccountInfoDouble(ACCOUNT_MARGIN);
      if(margin <= 0.0)
         OrderCalcMargin(type, _Symbol, volume, openPrice, margin);
      return(true);
     }

   type      = (InpDirection == NYESER_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   volume    = FullMarginLots(type);
   if(volume <= 0.0)
      volume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   markPrice = (type == ORDER_TYPE_BUY)
               ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
               : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   openPrice = markPrice;
   profit    = 0.0;
   if(!OrderCalcMargin(type, _Symbol, volume, openPrice, margin))
      margin = 0.0;
   return(volume > 0.0 && markPrice > 0.0);
  }

//+------------------------------------------------------------------+
void UpdateTargetLines()
  {
   ENUM_ORDER_TYPE type;
   double volume = 0.0, markPrice = 0.0, openPrice = 0.0, profit = 0.0, margin = 0.0;
   if(!PrepareLineModel(type, volume, markPrice, openPrice, profit, margin))
     {
      g_lineInfo = "garis: lot/harga belum siap";
      return;
     }

   double mppAbs = 0.0;
   if(!MoneyPerPriceMove(type, volume, openPrice, mppAbs) || mppAbs <= 0.0)
     {
      g_lineInfo = "garis: OrderCalcProfit gagal";
      return;
     }

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0.0)
      return;

   double tpMoney = balance * (InpProfitBasketPercent / 100.0);
   double slMoney = -balance * (InpLossLimitPercent / 100.0);
   double soMoney = StopOutTargetMoney(margin, profit);

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double tpPrice = NormalizeDouble(PriceForTargetMoney(type, volume, markPrice, profit, tpMoney, mppAbs), digits);
   double slPrice = NormalizeDouble(PriceForTargetMoney(type, volume, markPrice, profit, slMoney, mppAbs), digits);
   double soPrice = NormalizeDouble(PriceForTargetMoney(type, volume, markPrice, profit, soMoney, mppAbs), digits);

   DrawPriceLine(OBJ_LINE_PROFIT, tpPrice, clrLime, STYLE_SOLID,
                 "TP " + DoubleToString(InpProfitBasketPercent, 2) + "%  " + DoubleToString(tpPrice, digits));
   DrawPriceLine(OBJ_LINE_LOSS, slPrice, clrRed, STYLE_SOLID,
                 "Rugi " + DoubleToString(InpLossLimitPercent, 2) + "%  " + DoubleToString(slPrice, digits));
   DrawPriceLine(OBJ_LINE_SO, soPrice, clrOrange, STYLE_DASH,
                 "SO " + DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_SO_SO), 0)
                 + (AccountInfoInteger(ACCOUNT_MARGIN_SO_MODE) == ACCOUNT_STOPOUT_MODE_MONEY ? " " : "%  ")
                 + DoubleToString(soPrice, digits));

   if(InpFitChartToLines)
      FitChart(markPrice, tpPrice, slPrice, soPrice);

   g_lineInfo = "TP " + DoubleToString(tpPrice, digits)
                + "  rugi " + DoubleToString(slPrice, digits)
                + "  SO " + DoubleToString(soPrice, digits);
  }

//+------------------------------------------------------------------+
void DrawPriceLine(const string name, const double price, const color clr,
                   const ENUM_LINE_STYLE style, const string caption)
  {
   if(price <= 0.0)
      return;

   datetime t0 = iTime(_Symbol, PERIOD_CURRENT, MathMax(0, Bars(_Symbol, PERIOD_CURRENT) - 1));
   datetime t1 = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(t1 <= 0)
      t1 = TimeCurrent();
   if(t0 <= 0)
      t0 = t1 - PeriodSeconds() * 50;

   if(ObjectFind(g_chart, name) < 0)
     {
      if(!ObjectCreate(g_chart, name, OBJ_HLINE, 0, 0, price))
         ObjectCreate(g_chart, name, OBJ_TREND, 0, t0, price, t1, price);
     }

   ObjectSetDouble(g_chart, name, OBJPROP_PRICE, price);
   ObjectSetDouble(g_chart, name, OBJPROP_PRICE, 0, price);
   ObjectSetInteger(g_chart, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(g_chart, name, OBJPROP_STYLE, style);
   ObjectSetInteger(g_chart, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(g_chart, name, OBJPROP_BACK, false);
   ObjectSetInteger(g_chart, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(g_chart, name, OBJPROP_HIDDEN, false);
   ObjectSetInteger(g_chart, name, OBJPROP_TIMEFRAMES, OBJ_ALL_PERIODS);
   ObjectSetInteger(g_chart, name, OBJPROP_RAY_RIGHT, true);
   ObjectSetInteger(g_chart, name, OBJPROP_RAY_LEFT, true);
   ObjectSetString(g_chart, name, OBJPROP_TEXT, caption);
   ObjectSetString(g_chart, name, OBJPROP_TOOLTIP, caption);

   string arrowName = name + "_arrow";
   if(ObjectFind(g_chart, arrowName) < 0)
      ObjectCreate(g_chart, arrowName, OBJ_ARROW_RIGHT_PRICE, 0, t1, price);
   ObjectSetInteger(g_chart, arrowName, OBJPROP_TIME, t1);
   ObjectSetDouble(g_chart, arrowName, OBJPROP_PRICE, price);
   ObjectSetInteger(g_chart, arrowName, OBJPROP_COLOR, clr);
   ObjectSetInteger(g_chart, arrowName, OBJPROP_WIDTH, 2);
   ObjectSetInteger(g_chart, arrowName, OBJPROP_HIDDEN, false);
   ObjectSetInteger(g_chart, arrowName, OBJPROP_SELECTABLE, false);
   ObjectSetString(g_chart, arrowName, OBJPROP_TOOLTIP, caption);

   string labelName = name + "_tag";
   datetime tLabel = t1 + PeriodSeconds() * 2;
   if(ObjectFind(g_chart, labelName) < 0)
      ObjectCreate(g_chart, labelName, OBJ_TEXT, 0, tLabel, price);
   ObjectMove(g_chart, labelName, 0, tLabel, price);
   ObjectSetInteger(g_chart, labelName, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
   ObjectSetInteger(g_chart, labelName, OBJPROP_FONTSIZE, 10);
   ObjectSetString(g_chart, labelName, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(g_chart, labelName, OBJPROP_COLOR, clr);
   ObjectSetInteger(g_chart, labelName, OBJPROP_HIDDEN, false);
   ObjectSetInteger(g_chart, labelName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(g_chart, labelName, OBJPROP_TIMEFRAMES, OBJ_ALL_PERIODS);
   ObjectSetString(g_chart, labelName, OBJPROP_TEXT, "  " + caption);
  }

//+------------------------------------------------------------------+
void FitChart(const double mark, const double tp, const double sl, const double so)
  {
   double lo = mark;
   double hi = mark;
   if(tp > 0.0) { lo = MathMin(lo, tp); hi = MathMax(hi, tp); }
   if(sl > 0.0) { lo = MathMin(lo, sl); hi = MathMax(hi, sl); }
   if(so > 0.0) { lo = MathMin(lo, so); hi = MathMax(hi, so); }
   double pad = (hi - lo);
   if(pad <= 0.0)
      pad = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 50.0;
   pad *= 0.15;
   ChartSetInteger(g_chart, CHART_SCALEFIX, true);
   ChartSetDouble(g_chart, CHART_FIXED_MIN, lo - pad);
   ChartSetDouble(g_chart, CHART_FIXED_MAX, hi + pad);
  }

//+------------------------------------------------------------------+
void CreateWindow()
  {
   if(ObjectFind(g_chart, OBJ_WINDOW) < 0)
     {
      ObjectCreate(g_chart, OBJ_WINDOW, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(g_chart, OBJ_WINDOW, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(g_chart, OBJ_WINDOW, OBJPROP_XDISTANCE, 12);
      ObjectSetInteger(g_chart, OBJ_WINDOW, OBJPROP_YDISTANCE, 18);
      ObjectSetInteger(g_chart, OBJ_WINDOW, OBJPROP_XSIZE, 380);
      ObjectSetInteger(g_chart, OBJ_WINDOW, OBJPROP_YSIZE, 132);
      ObjectSetInteger(g_chart, OBJ_WINDOW, OBJPROP_BGCOLOR, C'12,16,24');
      ObjectSetInteger(g_chart, OBJ_WINDOW, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(g_chart, OBJ_WINDOW, OBJPROP_COLOR, C'0,180,255');
      ObjectSetInteger(g_chart, OBJ_WINDOW, OBJPROP_WIDTH, 1);
      ObjectSetInteger(g_chart, OBJ_WINDOW, OBJPROP_BACK, false);
      ObjectSetInteger(g_chart, OBJ_WINDOW, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(g_chart, OBJ_WINDOW, OBJPROP_HIDDEN, true);
     }

   CreateLabel(OBJ_SECONDS, 22, 28, 11, clrAqua);
   CreateLabel(OBJ_STATUS, 22, 52, 9, clrSilver);
  }

//+------------------------------------------------------------------+
void CreateLabel(const string name, const int x, const int y, const int size, const color clr)
  {
   if(ObjectFind(g_chart, name) >= 0)
      return;
   ObjectCreate(g_chart, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(g_chart, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(g_chart, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(g_chart, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(g_chart, name, OBJPROP_FONTSIZE, size);
   ObjectSetString(g_chart, name, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(g_chart, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(g_chart, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(g_chart, name, OBJPROP_HIDDEN, true);
  }

//+------------------------------------------------------------------+
void UpdateWindow()
  {
   CreateWindow();

   long unixSeconds = (long)TimeGMT();
   int basketSec = (g_basketStart > 0) ? (int)(TimeCurrent() - g_basketStart) : 0;

   double profit = 0.0, netVol = 0.0, vwap = 0.0;
   datetime oldest = 0;
   CollectBasket(profit, netVol, vwap, oldest);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double pct = (balance > 0.0) ? (profit / balance) * 100.0 : 0.0;

   string secLine = "1970  detik " + IntegerToString(unixSeconds) + "   keranjang " + IntegerToString(basketSec) + "s";
   string stLine  = StringFormat(
                       "nyeserpip  P/L %.2f%%  (TP %.2f / rugi %.2f)\ntiket %d/%d  lot %.2f/%.2f  %s\n%s",
                       pct,
                       InpProfitBasketPercent,
                       InpLossLimitPercent,
                       CountOurPositions(),
                       SliceCount(),
                       OurVolume(),
                       g_targetLots,
                       g_lastAction,
                       g_lineInfo);

   ObjectSetString(g_chart, OBJ_SECONDS, OBJPROP_TEXT, secLine);
   ObjectSetString(g_chart, OBJ_STATUS, OBJPROP_TEXT, stLine);
  }

//+------------------------------------------------------------------+
