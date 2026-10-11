//+------------------------------------------------------------------+
//|                                       TrendlineBounceManager.mq5 |
//|                                        Deva Gana LLC - Brittany  |
//|                                                                  |
//| Trendline bounce + supply/demand trade manager for XAUUSD (gold) |
//| on MetaTrader 5.                                                 |
//|                                                                  |
//| HOW IT WORKS                                                     |
//|  1. The trader draws objects manually on the chart:              |
//|     - Trendlines named starting with "BTT_" (e.g. BTT_TL1)        |
//|       Upward sloping line = support -> BUY on bounce             |
//|       Downward sloping line = resistance -> SELL on bounce       |
//|     - Rectangles named starting with "SDD_" = demand zone -> BUY |
//|     - Rectangles named starting with "SDS_" = supply zone -> SELL|
//|     Keep object names short (under ~20 chars) so the full name   |
//|     fits in the position comment used for trade tracking.        |
//|  2. On each new bar the EA checks the just-closed bar:           |
//|     - Trendline: bar extreme touched the line (within tolerance) |
//|       AND the bar closed back on the trend side (rejection).     |
//|     - Demand zone: bar low dipped into the zone and closed back  |
//|       above the zone bottom. Supply zone: mirrored logic.        |
//|  3. Stop loss goes beyond the line/zone by ATR buffer. Take      |
//|     profit defaults to 2.0R.                                     |
//|  4. Once price moves 1R in profit, the stop trails behind the    |
//|     most recent confirmed fractal swing.                         |
//|  5. If a candle CLOSES beyond the entry line/zone (genuine       |
//|     violation, not a wick), the position is closed.              |
//|                                                                  |
//| RISK (FTMO-friendly): fixed % risk per trade with lot sizing     |
//| from SL distance, max spread filter, max daily loss cutoff,      |
//| max open positions limit, magic number.                          |
//|                                                                  |
//| INSTALL                                                          |
//|  1. MT5 > File > Open Data Folder > MQL5 > Experts > paste this  |
//|     file.                                                        |
//|  2. Press F4 to open MetaEditor, open the file, press F7 to      |
//|     compile. Fix any errors before use.                          |
//|  3. Drag the EA onto an XAUUSD chart (15m or 4H recommended).    |
//|  4. Enable the "Algo Trading" button on the MT5 toolbar.         |
//|  5. Draw your BTT_ trendlines and SDD_/SDS_ rectangles. The EA    |
//|     does the rest.                                               |
//+------------------------------------------------------------------+
#property copyright "Deva Gana LLC"
#property version   "1.00"
#property description "Trendline bounce + supply/demand trade manager for XAUUSD."

#include <Trade\Trade.mqh>

//--- inputs: chart objects
input group "Chart Objects"
input string InpTrendPrefix  = "BTT_";   // Trendline name prefix
input string InpDemandPrefix = "SDD_";   // Demand zone (rectangle) prefix
input string InpSupplyPrefix = "SDS_";   // Supply zone (rectangle) prefix

//--- inputs: signal
input group "Signal Settings"
input int    InpAtrPeriod     = 14;      // ATR period
input double InpTouchTolAtr   = 0.25;    // Touch tolerance (x ATR)
input double InpSlBufferAtr   = 0.5;     // SL buffer beyond line/zone (x ATR)
input double InpTpRMultiple   = 2.0;     // Take profit (R multiple)

//--- inputs: risk
input group "Risk Management"
input double InpRiskPct         = 1.0;   // Risk per trade (% of balance)
input int    InpMaxSpreadPoints = 40;    // Max spread filter (points)
input double InpMaxDailyLossPct = 4.0;   // Max daily loss (% of balance, 0=off)
input int    InpMaxPositions    = 1;     // Max open positions

//--- inputs: trailing
input group "Trailing Stop"
input bool   InpUseTrailing    = true;   // Use fractal trailing stop
input double InpTrailStartR    = 1.0;    // Start trailing at profit (R)
input double InpTrailBufferAtr = 0.1;    // Trail buffer behind fractal (x ATR)

//--- inputs: general
input group "General"
input long   InpMagic        = 20261005; // Magic number
input string InpTradeComment = "TBM";     // Trade comment prefix

//--- globals
CTrade   trade;
int      atrHandle     = INVALID_HANDLE;
int      fractalHandle = INVALID_HANDLE;
datetime lastBarTime   = 0;
string   tradedKeys[];   // "ObjectName|BarTime" already traded

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpRiskPct <= 0 || InpRiskPct > 10)
     {
      Print("InpRiskPct must be between 0 and 10.");
      return INIT_FAILED;
     }
   if(InpTpRMultiple <= 0)
     {
      Print("InpTpRMultiple must be positive.");
      return INIT_FAILED;
     }
   if(StringLen(InpTrendPrefix) == 0)
     {
      Print("Trendline prefix must not be empty.");
      return INIT_FAILED;
     }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   atrHandle = iATR(_Symbol, PERIOD_CURRENT, InpAtrPeriod);
   fractalHandle = iFractals(_Symbol, PERIOD_CURRENT);
   if(atrHandle == INVALID_HANDLE || fractalHandle == INVALID_HANDLE)
     {
      Print("Failed to create indicator handles.");
      return INIT_FAILED;
     }

   Print("TrendlineBounceManager initialized on ", _Symbol,
         " ", EnumToString(PERIOD_CURRENT),
         " | Magic=", InpMagic,
         " | Risk=", DoubleToString(InpRiskPct, 2), "%");
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);
   if(fractalHandle != INVALID_HANDLE)
      IndicatorRelease(fractalHandle);
   Comment("");
  }

//+------------------------------------------------------------------+
//| Main tick handler: everything runs on the new bar                |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(!IsNewBar())
      return;
   if(atrHandle == INVALID_HANDLE || fractalHandle == INVALID_HANDLE)
      return;

   double atr = GetATR(1);               // last CLOSED bar ATR (no repaint)
   if(atr <= 0)
      return;

   double   tol      = InpTouchTolAtr * atr;
   double   barLow   = iLow(_Symbol, PERIOD_CURRENT, 1);
   double   barHigh  = iHigh(_Symbol, PERIOD_CURRENT, 1);
   double   barClose = iClose(_Symbol, PERIOD_CURRENT, 1);
   datetime barTime  = iTime(_Symbol, PERIOD_CURRENT, 1);

   ScanObjects(atr, tol, barTime, barLow, barHigh, barClose);
   ManagePositions(atr, tol, barTime, barClose);
   DrawStatus();
  }

//+------------------------------------------------------------------+
//| New bar detection                                                |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime t = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(t == 0)
      return false;
   if(t != lastBarTime)
     {
      lastBarTime = t;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| ATR value at shift                                               |
//+------------------------------------------------------------------+
double GetATR(int shift)
  {
   double buf[];
   if(CopyBuffer(atrHandle, 0, shift, 1, buf) < 1)
      return 0;
   return buf[0];
  }

//+------------------------------------------------------------------+
//| Scan chart objects for setups                                    |
//+------------------------------------------------------------------+
void ScanObjects(double atr, double tol, datetime barTime,
                 double barLow, double barHigh, double barClose)
  {
   int total = ObjectsTotal(0);
   for(int i = total - 1; i >= 0; i--)
     {
      string name = ObjectName(0, i);
      if(name == "")
         continue;
      if(StringFind(name, InpTrendPrefix) == 0)
         CheckTrendline(name, atr, tol, barTime, barLow, barHigh, barClose);
      else if(StringFind(name, InpDemandPrefix) == 0)
         CheckZone(name, true, atr, tol, barTime, barLow, barHigh, barClose);
      else if(StringFind(name, InpSupplyPrefix) == 0)
         CheckZone(name, false, atr, tol, barTime, barLow, barHigh, barClose);
     }
  }

//+------------------------------------------------------------------+
//| Trendline bounce signal                                          |
//+------------------------------------------------------------------+
void CheckTrendline(string name, double atr, double tol, datetime barTime,
                    double barLow, double barHigh, double barClose)
  {
   if(ObjectFind(0, name) < 0)
      return;
   if(ObjectGetInteger(0, name, OBJPROP_TYPE) != OBJ_TREND)
      return;

   double p1 = ObjectGetDouble(0, name, OBJPROP_PRICE, 1);
   double p2 = ObjectGetDouble(0, name, OBJPROP_PRICE, 2);
   if(p1 <= 0 || p2 <= 0)
      return;

   double linePrice = 0;
   if(!ObjectGetValueByTime(0, name, barTime, linePrice) || linePrice <= 0)
      return;

   string key = name + "|" + IntegerToString((long)barTime);
   if(AlreadyTraded(key))
      return;

   bool isSupport = (p2 > p1);   // upward line = support, downward = resistance

   if(isSupport)
     {
      // BUY: bar low touched the line and price closed back above it
      if(barLow <= linePrice + tol && barLow >= linePrice - tol && barClose > linePrice)
        {
         double sl = linePrice - InpSlBufferAtr * atr;
         OpenTrade(ORDER_TYPE_BUY, sl, key, name, 'T');
        }
     }
   else
     {
      // SELL: bar high touched the line and price closed back below it
      if(barHigh >= linePrice - tol && barHigh <= linePrice + tol && barClose < linePrice)
        {
         double sl = linePrice + InpSlBufferAtr * atr;
         OpenTrade(ORDER_TYPE_SELL, sl, key, name, 'T');
        }
     }
  }

//+------------------------------------------------------------------+
//| Supply/demand zone signal                                        |
//+------------------------------------------------------------------+
void CheckZone(string name, bool isDemand, double atr, double tol,
               datetime barTime, double barLow, double barHigh, double barClose)
  {
   if(ObjectFind(0, name) < 0)
      return;
   if(ObjectGetInteger(0, name, OBJPROP_TYPE) != OBJ_RECTANGLE)
      return;

   double top = ZoneTop(name);
   double bot = ZoneBottom(name);
   if(top <= 0 || bot <= 0 || top <= bot)
      return;

   string key = name + "|" + IntegerToString((long)barTime);
   if(AlreadyTraded(key))
      return;

   if(isDemand)
     {
      // BUY: bar low entered the zone and price closed back above the zone bottom
      if(barLow <= top + tol && barLow >= bot - tol && barClose > bot)
        {
         double sl = bot - InpSlBufferAtr * atr;
         OpenTrade(ORDER_TYPE_BUY, sl, key, name, 'D');
        }
     }
   else
     {
      // SELL: bar high entered the zone and price closed back below the zone top
      if(barHigh >= bot - tol && barHigh <= top + tol && barClose < top)
        {
         double sl = top + InpSlBufferAtr * atr;
         OpenTrade(ORDER_TYPE_SELL, sl, key, name, 'S');
        }
     }
  }

//+------------------------------------------------------------------+
//| Rectangle zone edges                                             |
//+------------------------------------------------------------------+
double ZoneTop(string name)
  {
   double pa = ObjectGetDouble(0, name, OBJPROP_PRICE, 1);
   double pb = ObjectGetDouble(0, name, OBJPROP_PRICE, 2);
   if(pa <= 0 || pb <= 0)
      return 0;
   return MathMax(pa, pb);
  }

double ZoneBottom(string name)
  {
   double pa = ObjectGetDouble(0, name, OBJPROP_PRICE, 1);
   double pb = ObjectGetDouble(0, name, OBJPROP_PRICE, 2);
   if(pa <= 0 || pb <= 0)
      return 0;
   return MathMin(pa, pb);
  }

//+------------------------------------------------------------------+
//| Open a trade with risk-based position sizing                     |
//+------------------------------------------------------------------+
void OpenTrade(ENUM_ORDER_TYPE type, double sl, string key, string objName, char kind)
  {
   //--- gates
   if(CountMyPositions() >= InpMaxPositions)
      return;
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpreadPoints)
     {
      Print("Entry skipped on ", objName, ": spread ", spread,
            " pts > max ", InpMaxSpreadPoints, " pts.");
      return;
     }
   if(DailyLossExceeded())
     {
      Print("Entry skipped on ", objName, ": daily loss limit reached.");
      return;
     }

   double price = (type == ORDER_TYPE_BUY)
                  ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                  : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double riskDist = (type == ORDER_TYPE_BUY) ? price - sl : sl - price;

   //--- broker stop level check
   double minDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(riskDist <= MathMax(minDist, _Point))
     {
      Print("Entry skipped on ", objName, ": SL distance too small.");
      return;
     }

   double lots = CalcLots(riskDist);
   if(lots <= 0)
     {
      Print("Entry skipped on ", objName, ": lot calculation failed.");
      return;
     }

   double tp = (type == ORDER_TYPE_BUY)
               ? price + InpTpRMultiple * riskDist
               : price - InpTpRMultiple * riskDist;
   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

   //--- comment encodes object for violation tracking (31 char broker limit)
   string cmt = InpTradeComment + "|" + CharToString(kind) + "|" + objName;
   cmt = StringSubstr(cmt, 0, 31);

   bool ok = (type == ORDER_TYPE_BUY)
             ? trade.Buy(lots, _Symbol, 0.0, sl, tp, cmt)
             : trade.Sell(lots, _Symbol, 0.0, sl, tp, cmt);

   if(ok)
     {
      MarkTraded(key);
      Print((type == ORDER_TYPE_BUY ? "BUY " : "SELL "), DoubleToString(lots, 2),
            " ", _Symbol, " @", DoubleToString(price, _Digits),
            " SL=", DoubleToString(sl, _Digits),
            " TP=", DoubleToString(tp, _Digits),
            " [", objName, "]");
     }
   else
     {
      Print("Order failed on ", objName, ": retcode=",
            trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| Risk-based lot size from SL distance (price units)               |
//+------------------------------------------------------------------+
double CalcLots(double slDistance)
  {
   if(slDistance <= 0)
      return 0;
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * InpRiskPct / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0 || tickSize <= 0 || riskMoney <= 0)
      return 0;

   double lossPerLot = (slDistance / tickSize) * tickValue;
   if(lossPerLot <= 0)
      return 0;

   double lots  = riskMoney / lossPerLot;
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0)
      return 0;

   lots = MathFloor(lots / step) * step;
   lots = MathMin(MathMax(lots, minLot), maxLot);

   int lotDigits = 0;
   double s = step;
   while(s < 1.0 && lotDigits < 8)
     {
      s *= 10;
      lotDigits++;
     }
   return NormalizeDouble(lots, lotDigits);
  }

//+------------------------------------------------------------------+
//| Count our open positions on this symbol                          |
//+------------------------------------------------------------------+
int CountMyPositions()
  {
   int cnt = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      cnt++;
     }
   return cnt;
  }

//+------------------------------------------------------------------+
//| Today's closed P/L for our magic number                          |
//+------------------------------------------------------------------+
double TodayClosedPL()
  {
   datetime dayStart = iTime(_Symbol, PERIOD_D1, 0);
   if(dayStart == 0)
      return 0;
   if(!HistorySelect(dayStart, TimeCurrent() + 60))
      return 0;

   double pl = 0;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol)
         continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagic)
         continue;
      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT)
         continue;
      pl += HistoryDealGetDouble(ticket, DEAL_PROFIT)
          + HistoryDealGetDouble(ticket, DEAL_SWAP)
          + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
     }
   return pl;
  }

//+------------------------------------------------------------------+
//| Daily loss circuit breaker                                       |
//+------------------------------------------------------------------+
bool DailyLossExceeded()
  {
   if(InpMaxDailyLossPct <= 0)
      return false;
   double pl      = TodayClosedPL();
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   return (pl <= -(InpMaxDailyLossPct / 100.0) * balance);
  }

//+------------------------------------------------------------------+
//| Manage open positions: violation exits + fractal trailing        |
//+------------------------------------------------------------------+
void ManagePositions(double atr, double tol, datetime barTime, double barClose)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      long   ptype = PositionGetInteger(POSITION_TYPE);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      string cmt   = PositionGetString(POSITION_COMMENT);

      //--- parse "TBM|T|BTT_TL1"
      string parts[];
      int n = StringSplit(cmt, '|', parts);
      string objName = (n >= 3) ? parts[2] : "";
      int kind = -1;   // 0=trend, 1=demand, 2=supply
      if(n >= 2)
        {
         if(parts[1] == "T")
            kind = 0;
         else if(parts[1] == "D")
            kind = 1;
         else if(parts[1] == "S")
            kind = 2;
        }

      //--- 1) genuine violation exit: candle CLOSED beyond the line/zone
      bool violated = false;
      if(kind >= 0 && objName != "" && ObjectFind(0, objName) >= 0)
        {
         if(kind == 0)
           {
            double linePrice = 0;
            if(ObjectGetValueByTime(0, objName, barTime, linePrice) && linePrice > 0)
              {
               if(ptype == POSITION_TYPE_BUY && barClose < linePrice - tol)
                  violated = true;
               if(ptype == POSITION_TYPE_SELL && barClose > linePrice + tol)
                  violated = true;
              }
           }
         else if(kind == 1)   // demand long: violation = close under zone bottom
           {
            double bot = ZoneBottom(objName);
            if(bot > 0 && ptype == POSITION_TYPE_BUY && barClose < bot - tol)
               violated = true;
           }
         else if(kind == 2)   // supply short: violation = close over zone top
           {
            double top = ZoneTop(objName);
            if(top > 0 && ptype == POSITION_TYPE_SELL && barClose > top + tol)
               violated = true;
           }
        }
      if(violated)
        {
         if(trade.PositionClose(ticket))
            Print("Closed #", ticket, " [", objName, "]: line/zone violated by close.");
         else
            Print("Close failed #", ticket, ": ", trade.ResultRetcodeDescription());
         continue;
        }

      //--- 2) fractal trailing stop
      if(InpUseTrailing)
         TrailPosition(ticket, ptype, entry, curSL, tp, atr);
     }
  }

//+------------------------------------------------------------------+
//| Trail stop behind the most recent confirmed fractal swing        |
//+------------------------------------------------------------------+
void TrailPosition(ulong ticket, long ptype, double entry, double curSL,
                   double tp, double atr)
  {
   if(tp <= 0 || InpTpRMultiple <= 0)
      return;
   // Original risk recovered from the TP set at entry (TP is never moved)
   double origRisk = MathAbs(tp - entry) / InpTpRMultiple;
   if(origRisk <= 0)
      return;

   double buf       = InpTrailBufferAtr * atr;
   double minDist   = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double bid       = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask       = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(ptype == POSITION_TYPE_BUY)
     {
      if(bid - entry < InpTrailStartR * origRisk)
         return;                       // not yet 1R in profit
      double fl = LastFractalLow();
      if(fl <= 0)
         return;
      double newSL = NormalizeDouble(fl - buf, _Digits);
      if(newSL <= curSL)
         return;                       // only move up
      if(newSL >= bid - MathMax(minDist, _Point))
         return;                       // respect broker stop level
      if(trade.PositionModify(ticket, newSL, tp))
         Print("Trailed #", ticket, " SL -> ", DoubleToString(newSL, _Digits));
     }
   else if(ptype == POSITION_TYPE_SELL)
     {
      if(entry - ask < InpTrailStartR * origRisk)
         return;
      double fh = LastFractalHigh();
      if(fh <= 0)
         return;
      double newSL = NormalizeDouble(fh + buf, _Digits);
      if(curSL > 0 && newSL >= curSL)
         return;                       // only move down
      if(newSL <= ask + MathMax(minDist, _Point))
         return;
      if(trade.PositionModify(ticket, newSL, tp))
         Print("Trailed #", ticket, " SL -> ", DoubleToString(newSL, _Digits));
     }
  }

//+------------------------------------------------------------------+
//| Most recent confirmed fractal swing low/high (lag = 2 bars)      |
//+------------------------------------------------------------------+
double LastFractalLow()
  {
   double buf[];
   if(CopyBuffer(fractalHandle, 1, 2, 50, buf) < 1)   // buffer 1 = lower
      return 0;
   for(int i = 0; i < ArraySize(buf); i++)
      if(buf[i] > 0)
         return buf[i];
   return 0;
  }

double LastFractalHigh()
  {
   double buf[];
   if(CopyBuffer(fractalHandle, 0, 2, 50, buf) < 1)   // buffer 0 = upper
      return 0;
   for(int i = 0; i < ArraySize(buf); i++)
      if(buf[i] > 0)
         return buf[i];
   return 0;
  }

//+------------------------------------------------------------------+
//| One position per object per touch bar                            |
//+------------------------------------------------------------------+
bool AlreadyTraded(string key)
  {
   for(int i = 0; i < ArraySize(tradedKeys); i++)
      if(tradedKeys[i] == key)
         return true;
   return false;
  }

void MarkTraded(string key)
  {
   int n = ArraySize(tradedKeys);
   ArrayResize(tradedKeys, n + 1);
   tradedKeys[n] = key;
   if(ArraySize(tradedKeys) > 500)   // cap memory
      ArrayRemove(tradedKeys, 0, ArraySize(tradedKeys) - 500);
  }

//+------------------------------------------------------------------+
//| On-chart status panel                                            |
//+------------------------------------------------------------------+
void DrawStatus()
  {
   string s = StringFormat(
      "TrendlineBounceManager | %s %s\nMagic %I64d | Positions %d | Today P/L %.2f",
      _Symbol, EnumToString(PERIOD_CURRENT),
      InpMagic, CountMyPositions(), TodayClosedPL());
   if(DailyLossExceeded())
      s += "\n!! DAILY LOSS LIMIT REACHED - no new entries today !!";
   Comment(s);
  }
//+------------------------------------------------------------------+
