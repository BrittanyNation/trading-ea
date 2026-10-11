//+------------------------------------------------------------------+
//|                                            SupplyDemandAuto.mq5  |
//|                                        Deva Gana LLC - Brittany  |
//|                                                                  |
//| FULLY AUTOMATIC supply & demand Expert Advisor for XAUUSD        |
//| (gold) on MetaTrader 5. No manual drawing, no trendlines.        |
//|                                                                  |
//| WHAT IT DOES                                                     |
//|  1. AUTO-DETECTS supply and demand zones on the 4H chart from    |
//|     strong impulsive moves away from a small-bodied base:        |
//|     rally-base-rally -> demand zone, drop-base-drop -> supply.   |
//|     The zone is marked from the base bar's high/low. Only        |
//|     significant impulses (configurable ATR multiple) qualify.    |
//|  2. ENTRIES on the 15m chart when price returns to a FRESH,      |
//|     unmitigated zone and confirms: a rejection wick or an        |
//|     engulfing candle in the zone's direction. Demand = BUY,      |
//|     supply = SELL.                                               |
//|  3. ZONE FRESHNESS: a zone dies after the first entry taken      |
//|     from it, after price CLOSES beyond it (mitigation), or       |
//|     after a max age in bars - whichever comes first. Dead zones  |
//|     are never re-detected.                                       |
//|  4. STOP goes beyond the far edge of the zone plus a buffer.     |
//|     TAKE PROFIT defaults to 2R. Optional trailing after 1R. A     |
//|     4H close beyond the zone exits the trade early.              |
//|  5. FTMO-STYLE GUARDS: fixed fractional risk per trade, one      |
//|     position per symbol, max spread filter, optional trading-    |
//|     hours filter, and a daily-loss circuit breaker that halts    |
//|     new entries for the rest of the day.                         |
//|                                                                  |
//| IMPORTANT                                                        |
//|  - This is an UNTESTED automation of a supply/demand rule set.   |
//|    It has no proven profitability. Forward-test on DEMO first,   |
//|    ideally for several weeks across different market regimes,    |
//|    before considering any live use.                              |
//|  - No martingale, no grid, no averaging down. Fixed fractional   |
//|    risk only.                                                    |
//|  - Attach to an XAUUSD H4 chart. The EA reads M15 data itself    |
//|    for entry confirmation.                                       |
//|                                                                  |
//| INSTALL                                                          |
//|  1. MT5 > File > Open Data Folder > MQL5 > Experts > paste this  |
//|     file.                                                        |
//|  2. Press F4 to open MetaEditor, open the file, press F7 to      |
//|     compile. Fix any errors before use.                          |
//|  3. Drag the EA onto an XAUUSD H4 chart.                         |
//|  4. Enable the "Algo Trading" button on the MT5 toolbar.         |
//+------------------------------------------------------------------+
#property copyright "Deva Gana LLC"
#property version   "1.00"
#property description "Fully automatic supply/demand EA for XAUUSD (H4 zones + M15 confirmation). UNTESTED - demo forward-test required."

#include <Trade\Trade.mqh>

//--- inputs: zone detection (H4)
input group "Zone Detection (H4)"
input double InpImpulseAtr    = 2.0;    // Min impulse body to mark a zone (x ATR)
input double InpBaseMaxAtr     = 0.6;    // Max base-bar body (x ATR)
input int    InpBaseSearchBars = 3;      // Bars searched back for the base
input int    InpZoneLookback   = 150;    // H4 bars scanned for new zones
input int    InpZoneMaxAgeBars = 60;     // Zone expiry (H4 bars)
input double InpTouchTolAtr    = 0.25;   // Zone touch tolerance (x ATR)
input double InpMitigTolAtr    = 0.25;   // Mitigation close tolerance (x ATR)
input bool   InpOneTapPerZone  = true;   // Retire zone after first entry

//--- inputs: entry confirmation (M15)
input group "Entry Confirmation (M15)"
input double InpWickMinFrac  = 0.30;    // Min rejection wick (fraction of range)
input bool   InpUseEngulfing = true;    // Also accept engulfing confirmation

//--- inputs: trade construction
input group "Trade Construction"
input double InpSlBufferAtr = 0.50;     // SL buffer beyond zone edge (x ATR)
input double InpTpRMultiple = 2.0;      // Take profit (R multiple)

//--- inputs: trailing
input group "Trailing Stop"
input bool   InpUseTrailing    = true;  // Trail behind fractal swings
input double InpTrailStartR    = 1.0;   // Start trailing at profit (R)
input double InpTrailBufferAtr = 0.10;  // Trail buffer behind fractal (x ATR)

//--- inputs: risk
input group "Risk Management"
input double InpRiskPct         = 1.0;  // Risk per trade (% of equity)
input int    InpMaxSpreadPoints = 40;   // Max spread filter (points)
input double InpMaxDailyLossPct = 4.0;  // Daily loss halt (% of day-start equity, 0=off)
input int    InpMaxPositions    = 1;    // Max open positions (this symbol+magic)

//--- inputs: time filter
input group "Trading Hours (server time, optional)"
input bool   InpUseTimeFilter = false;  // Enable trading-hours filter
input int    InpStartHour     = 7;      // Start hour (0-23)
input int    InpEndHour       = 20;     // End hour (0-23)

//--- inputs: general
input group "General"
input long   InpMagic        = 20261009; // Magic number
input string InpTradeComment = "SDA";   // Trade comment prefix (keep short)

//--- structs
struct SDZone
  {
   datetime          t;                  // base bar time
   double            top;
   double            bot;
   bool              isDemand;
   bool              valid;
  };

//--- globals
CTrade     trade;
int        atrHandle     = INVALID_HANDLE;
int        fractalHandle = INVALID_HANDLE;
datetime   lastH4Bar     = 0;
datetime   lastM15Bar    = 0;
bool       firstRun      = true;
SDZone     liveZones[];                 // tradeable zones
datetime   deadTimes[];                 // base times of retired zones (never re-add)
string     tradedKeys[];                // "D|zoneTime" / "S|zoneTime" already taken
datetime   dayRef        = 0;
double     dayStartEquity= 0;
int        atrPeriod     = 14;

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
   if(InpImpulseAtr <= 0 || InpBaseMaxAtr <= 0)
     {
      Print("Impulse and base ATR multiples must be positive.");
      return INIT_FAILED;
     }
   if(InpMaxPositions < 1)
     {
      Print("InpMaxPositions must be at least 1.");
      return INIT_FAILED;
     }
   if(InpStartHour < 0 || InpStartHour > 23 || InpEndHour < 0 || InpEndHour > 23)
     {
      Print("Trading hours must be 0-23.");
      return INIT_FAILED;
     }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   atrHandle     = iATR(_Symbol, PERIOD_H4, atrPeriod);
   fractalHandle = iFractals(_Symbol, PERIOD_H4);
   if(atrHandle == INVALID_HANDLE || fractalHandle == INVALID_HANDLE)
     {
      Print("Failed to create indicator handles.");
      return INIT_FAILED;
     }

   ArrayResize(liveZones, 0);
   ArrayResize(deadTimes, 0);
   ArrayResize(tradedKeys, 0);

   Print("SupplyDemandAuto initialized on ", _Symbol,
         " | Magic=", InpMagic,
         " | Risk=", DoubleToString(InpRiskPct, 2), "%",
         " | TP=", DoubleToString(InpTpRMultiple, 1), "R",
         " | Engulfing=", (InpUseEngulfing ? "ON" : "OFF"));
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
   DeleteMyObjects();
   Comment("");
  }

//+------------------------------------------------------------------+
//| Main tick handler                                                |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(atrHandle == INVALID_HANDLE || fractalHandle == INVALID_HANDLE)
      return;

   bool newH4  = IsNewBarTF(PERIOD_H4,  lastH4Bar);
   bool newM15 = IsNewBarTF(PERIOD_M15, lastM15Bar);
   if(!newH4 && !newM15 && !firstRun)
      return;
   firstRun = false;

   double atr = GetATR(1);               // last CLOSED H4 bar ATR (no repaint)
   if(atr <= 0)
      return;

   UpdateDayRef();

   if(newH4)
      UpdateZones(atr);                 // age/mitigation + detect new, redraw
   if(newM15 || newH4)
      CheckEntries(atr);

   ManagePositions(atr);
   DrawStatus();
  }

//+------------------------------------------------------------------+
//| New-bar detection per timeframe                                  |
//+------------------------------------------------------------------+
bool IsNewBarTF(ENUM_TIMEFRAMES tf, datetime &last)
  {
   datetime t = iTime(_Symbol, tf, 0);
   if(t == 0)
      return false;
   if(t != last)
     {
      last = t;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| ATR value at shift (H4)                                          |
//+------------------------------------------------------------------+
double GetATR(int shift)
  {
   double buf[];
   if(CopyBuffer(atrHandle, 0, shift, 1, buf) < 1)
      return 0;
   return buf[0];
  }

//+------------------------------------------------------------------+
//| Zone lifecycle: retire aged/mitigated zones, detect new ones     |
//+------------------------------------------------------------------+
void UpdateZones(double atr)
  {
   double violTol = InpMitigTolAtr * atr;
   double maxAgeSec = (double)InpZoneMaxAgeBars * 14400.0;
   datetime nowT = TimeCurrent();

   //--- 1) check existing zones
   for(int i = ArraySize(liveZones) - 1; i >= 0; i--)
     {
      if(!liveZones[i].valid)
         continue;

      // age
      if((double)(nowT - liveZones[i].t) > maxAgeSec)
        {
         RetireZone(i, "expired");
         continue;
        }

      // mitigation: any H4 close beyond the far edge since the zone formed
      int idx = iBarShift(_Symbol, PERIOD_H4, liveZones[i].t);
      if(idx < 1)
         continue;                        // base bar not in history; keep
      if(idx > InpZoneLookback + 20)
         idx = InpZoneLookback + 20;

      bool mitigated = false;
      for(int b = 1; b <= idx; b++)
        {
         double c = iClose(_Symbol, PERIOD_H4, b);
         if(c <= 0)
            continue;
         if(liveZones[i].isDemand && c < liveZones[i].bot - violTol)
           { mitigated = true; break; }
         if(!liveZones[i].isDemand && c > liveZones[i].top + violTol)
           { mitigated = true; break; }
        }
      if(mitigated)
         RetireZone(i, "mitigated");
     }

   //--- 2) detect new zones
   DetectNewZones(atr);

   //--- 3) compact the array when it gets cluttered
   if(ArraySize(liveZones) > 40)
      CompactZones();

   DrawZones();
   Print("Zone update: ", CountValidZones(), " live zones.");
  }

//+------------------------------------------------------------------+
//| Retire a zone: mark invalid and remember its base time           |
//+------------------------------------------------------------------+
void RetireZone(int i, string reason)
  {
   Print("Zone retired (", reason, "): ",
         (liveZones[i].isDemand ? "demand " : "supply "),
         DoubleToString(liveZones[i].bot, _Digits), "-",
         DoubleToString(liveZones[i].top, _Digits));
   RememberDead(liveZones[i].t);
   liveZones[i].valid = false;
  }

void RememberDead(datetime t)
  {
   for(int i = 0; i < ArraySize(deadTimes); i++)
      if(deadTimes[i] == t)
         return;
   int n = ArraySize(deadTimes);
   ArrayResize(deadTimes, n + 1);
   deadTimes[n] = t;
   if(ArraySize(deadTimes) > 300)
      ArrayRemove(deadTimes, 0, ArraySize(deadTimes) - 300);
  }

bool IsDeadTime(datetime t)
  {
   for(int i = 0; i < ArraySize(deadTimes); i++)
      if(deadTimes[i] == t)
         return true;
   return false;
  }

int CountValidZones()
  {
   int c = 0;
   for(int i = 0; i < ArraySize(liveZones); i++)
      if(liveZones[i].valid)
         c++;
   return c;
  }

void CompactZones()
  {
   int w = 0;
   for(int i = 0; i < ArraySize(liveZones); i++)
     {
      if(liveZones[i].valid)
        {
         if(w != i)
            liveZones[w] = liveZones[i];
         w++;
        }
     }
   ArrayResize(liveZones, w);
  }

//+------------------------------------------------------------------+
//| Detect new zones from impulsive H4 moves                         |
//+------------------------------------------------------------------+
void DetectNewZones(double atr)
  {
   int n = InpZoneLookback + 5;
   double oo[], hh[], ll[], cc[];
   datetime tt[];
   if(CopyOpen(_Symbol, PERIOD_H4, 0, n, oo) < n)  return;
   if(CopyHigh(_Symbol, PERIOD_H4, 0, n, hh) < n)  return;
   if(CopyLow(_Symbol, PERIOD_H4, 0, n, ll) < n)   return;
   if(CopyClose(_Symbol, PERIOD_H4, 0, n, cc) < n) return;
   if(CopyTime(_Symbol, PERIOD_H4, 0, n, tt) < n)  return;

   double impulseMin = InpImpulseAtr * atr;
   double baseMax    = InpBaseMaxAtr * atr;

   for(int i = 1; i <= InpZoneLookback; i++)
     {
      double body = MathAbs(cc[i] - oo[i]);
      if(body < impulseMin)
         continue;

      // base = small-bodied bar within a few bars before the impulse
      for(int b = i + 1; b <= i + InpBaseSearchBars && b <= InpZoneLookback + 2; b++)
        {
         if(MathAbs(cc[b] - oo[b]) > baseMax)
            continue;
         if(hh[b] <= 0 || ll[b] <= 0 || hh[b] <= ll[b])
            break;

         SDZone z;
         z.isDemand = (cc[i] > oo[i]);     // rally-base-rally vs drop-base-drop
         z.top      = hh[b];
         z.bot      = ll[b];
         z.t        = tt[b];
         z.valid    = true;

         if(IsDeadTime(z.t))
            break;                          // retired before; never re-add
         if(OverlapsLive(z))
            break;                          // already tracked

         // the zone must not already be mitigated by price action since
         bool ok = true;
         double violTol = InpMitigTolAtr * atr;
         for(int k = 1; k < b; k++)
           {
            if(z.isDemand && cc[k] < z.bot - violTol)
              { ok = false; break; }
            if(!z.isDemand && cc[k] > z.top + violTol)
              { ok = false; break; }
           }
         if(!ok)
           {
            RememberDead(z.t);
            break;
           }

         int zn = ArraySize(liveZones);
         if(zn < 20)
           {
            ArrayResize(liveZones, zn + 1);
            liveZones[zn] = z;
            Print("New ", (z.isDemand ? "demand" : "supply"), " zone: ",
                  DoubleToString(z.bot, _Digits), "-",
                  DoubleToString(z.top, _Digits));
           }
         break;   // one zone per impulse bar
        }
     }
  }

//+------------------------------------------------------------------+
//| Skip a candidate that overlaps an already-live zone              |
//+------------------------------------------------------------------+
bool OverlapsLive(const SDZone &cand)
  {
   for(int i = 0; i < ArraySize(liveZones); i++)
     {
      if(!liveZones[i].valid)
         continue;
      if(liveZones[i].isDemand != cand.isDemand)
         continue;
      double dtSec = MathAbs((double)(liveZones[i].t - cand.t));
      if(dtSec > 5 * 14400.0)
         continue;
      bool priceOverlap = !(cand.top < liveZones[i].bot || cand.bot > liveZones[i].top);
      if(priceOverlap)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Draw live zones as chart rectangles                              |
//+------------------------------------------------------------------+
void DrawZones()
  {
   DeleteMyObjects();
   int drawn = 0;
   for(int i = 0; i < ArraySize(liveZones); i++)
     {
      if(!liveZones[i].valid)
         continue;
      string name = "SDA_Z" + IntegerToString(drawn);
      datetime t2 = TimeCurrent() + 20 * 14400;
      if(!ObjectCreate(0, name, OBJ_RECTANGLE, 0,
                       liveZones[i].t, liveZones[i].top, t2, liveZones[i].bot))
         continue;
      ObjectSetInteger(0, name, OBJPROP_FILL, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      color c = liveZones[i].isDemand ? C'0,150,0' : C'180,0,0';
      ObjectSetInteger(0, name, OBJPROP_COLOR, c);
      ObjectSetString(0, name, OBJPROP_TEXT,
                      liveZones[i].isDemand ? "SDA demand" : "SDA supply");
      drawn++;
     }
   ChartRedraw();
  }

void DeleteMyObjects()
  {
   for(int i = ObjectsTotal(0) - 1; i >= 0; i--)
     {
      string name = ObjectName(0, i);
      if(StringFind(name, "SDA_") == 0)
         ObjectDelete(0, name);
     }
  }

//+------------------------------------------------------------------+
//| Check for entries on fresh M15/H4 bars                           |
//+------------------------------------------------------------------+
void CheckEntries(double atr)
  {
   if(CountValidZones() == 0)
      return;
   if(!EntryGatesPass())
      return;

   double tol = InpTouchTolAtr * atr;
   datetime sigBar = iTime(_Symbol, PERIOD_M15, 1);   // just-closed M15 bar

   for(int i = ArraySize(liveZones) - 1; i >= 0; i--)   // newest first
     {
      if(!liveZones[i].valid)
         continue;
      // key is per zone per signal bar, so retests can trade when
      // one-tap-per-zone is disabled
      string key = (liveZones[i].isDemand ? "D|" : "S|") +
                   IntegerToString((long)liveZones[i].t) + "|" +
                   IntegerToString((long)sigBar);
      if(AlreadyTraded(key))
         continue;

      if(liveZones[i].isDemand)
         TryDemandEntry(i, tol, atr, key);
      else
         TrySupplyEntry(i, tol, atr, key);
     }
  }

//+------------------------------------------------------------------+
//| All pre-entry gates                                              |
//+------------------------------------------------------------------+
bool EntryGatesPass()
  {
   if(CountMyPositions() >= InpMaxPositions)
      return false;

   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpreadPoints)
     {
      Print("Entry skipped: spread ", spread, " pts > max ", InpMaxSpreadPoints, " pts.");
      return false;
     }

   if(DailyLossHalted())
     {
      Print("Entry skipped: daily loss limit reached.");
      return false;
     }

   if(!TimeAllowed())
      return false;

   return true;
  }

//+------------------------------------------------------------------+
//| Demand entry: M15 bar tapped the zone and confirmed bullish      |
//+------------------------------------------------------------------+
void TryDemandEntry(int zi, double tol, double atr, string key)
  {
   double o = iOpen(_Symbol, PERIOD_M15, 1);
   double h = iHigh(_Symbol, PERIOD_M15, 1);
   double l = iLow(_Symbol, PERIOD_M15, 1);
   double c = iClose(_Symbol, PERIOD_M15, 1);
   if(o <= 0 || h <= 0 || l <= 0 || c <= 0)
      return;

   double top = liveZones[zi].top;
   double bot = liveZones[zi].bot;

   // closed through the zone on M15: zone is dead immediately
   if(c < bot - tol)
     {
      RetireZone(zi, "M15 close-through");
      DrawZones();
      return;
     }

   // must have entered the zone
   if(l > top + tol)
      return;

   bool confirmed = BullishReject(o, h, l, c);
   if(!confirmed && InpUseEngulfing)
      confirmed = BullishEngulf();

   if(confirmed)
      OpenZoneTrade(true, zi, atr, key);
  }

//+------------------------------------------------------------------+
//| Supply entry: mirror image                                       |
//+------------------------------------------------------------------+
void TrySupplyEntry(int zi, double tol, double atr, string key)
  {
   double o = iOpen(_Symbol, PERIOD_M15, 1);
   double h = iHigh(_Symbol, PERIOD_M15, 1);
   double l = iLow(_Symbol, PERIOD_M15, 1);
   double c = iClose(_Symbol, PERIOD_M15, 1);
   if(o <= 0 || h <= 0 || l <= 0 || c <= 0)
      return;

   double top = liveZones[zi].top;
   double bot = liveZones[zi].bot;

   if(c > top + tol)
     {
      RetireZone(zi, "M15 close-through");
      DrawZones();
      return;
     }

   if(h < bot - tol)
      return;

   bool confirmed = BearishReject(o, h, l, c);
   if(!confirmed && InpUseEngulfing)
      confirmed = BearishEngulf();

   if(confirmed)
      OpenZoneTrade(false, zi, atr, key);
  }

//+------------------------------------------------------------------+
//| Confirmation patterns (M15, just-closed bar)                     |
//+------------------------------------------------------------------+
bool BullishReject(double o, double h, double l, double c)
  {
   double range = h - l;
   if(range <= 0)
      return false;
   double lowerWick = MathMin(o, c) - l;
   if(lowerWick < InpWickMinFrac * range)
      return false;
   if((c - l) / range < 0.5)
      return false;                       // close in upper half
   return (c > o);                         // bullish bar
  }

bool BearishReject(double o, double h, double l, double c)
  {
   double range = h - l;
   if(range <= 0)
      return false;
   double upperWick = h - MathMax(o, c);
   if(upperWick < InpWickMinFrac * range)
      return false;
   if((h - c) / range < 0.5)
      return false;
   return (c < o);
  }

bool BullishEngulf()
  {
   double o1 = iOpen(_Symbol, PERIOD_M15, 1);
   double c1 = iClose(_Symbol, PERIOD_M15, 1);
   double o2 = iOpen(_Symbol, PERIOD_M15, 2);
   double c2 = iClose(_Symbol, PERIOD_M15, 2);
   if(o1 <= 0 || c1 <= 0 || o2 <= 0 || c2 <= 0)
      return false;
   if(!(c1 > o1))
      return false;                       // current bar bullish
   if(!(c1 > o2 && o1 < c2))
      return false;                       // body engulfs prior body
   return true;
  }

bool BearishEngulf()
  {
   double o1 = iOpen(_Symbol, PERIOD_M15, 1);
   double c1 = iClose(_Symbol, PERIOD_M15, 1);
   double o2 = iOpen(_Symbol, PERIOD_M15, 2);
   double c2 = iClose(_Symbol, PERIOD_M15, 2);
   if(o1 <= 0 || c1 <= 0 || o2 <= 0 || c2 <= 0)
      return false;
   if(!(c1 < o1))
      return false;
   if(!(c1 < o2 && o1 > c2))
      return false;
   return true;
  }

//+------------------------------------------------------------------+
//| Open the zone trade: SL beyond far edge, TP at R multiple       |
//+------------------------------------------------------------------+
void OpenZoneTrade(bool isBuy, int zi, double atr, string key)
  {
   double top = liveZones[zi].top;
   double bot = liveZones[zi].bot;

   double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                        : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double buf = InpSlBufferAtr * atr;
   double sl  = isBuy ? bot - buf : top + buf;
   double riskDist = isBuy ? price - sl : sl - price;

   double minDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(riskDist <= MathMax(minDist, _Point))
     {
      Print("Entry skipped: SL distance too small.");
      return;
     }

   double lots = CalcLots(riskDist);
   if(lots <= 0)
     {
      Print("Entry skipped: lot calculation failed.");
      return;
     }

   double tp = isBuy ? price + InpTpRMultiple * riskDist
                     : price - InpTpRMultiple * riskDist;
   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

   // comment encodes the zone for violation exits: "<prefix>|D|<bot>|<top>"
   string cmt = StringFormat("%s|%s|%.2f|%.2f", InpTradeComment,
                             isBuy ? "D" : "S", bot, top);

   bool ok = isBuy ? trade.Buy(lots, _Symbol, 0.0, sl, tp, cmt)
                   : trade.Sell(lots, _Symbol, 0.0, sl, tp, cmt);
   if(ok)
     {
      MarkTraded(key);
      if(InpOneTapPerZone)
        {
         RetireZone(zi, "first tap traded");
         DrawZones();
        }
      Print((isBuy ? "BUY " : "SELL "), DoubleToString(lots, 2),
            " ", _Symbol, " @", DoubleToString(price, _Digits),
            " SL=", DoubleToString(sl, _Digits),
            " TP=", DoubleToString(tp, _Digits),
            " [", (isBuy ? "demand" : "supply"), " zone]");
     }
   else
      Print("Order failed: retcode=", trade.ResultRetcode(), " ",
            trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| Risk-based lot size from SL distance (price units)               |
//+------------------------------------------------------------------+
double CalcLots(double slDistance)
  {
   if(slDistance <= 0)
      return 0;
   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * InpRiskPct / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0 || tickSize <= 0 || riskMoney <= 0)
      return 0;

   double lossPerLot = (slDistance / tickSize) * tickValue;
   if(lossPerLot <= 0)
      return 0;

   double lots   = riskMoney / lossPerLot;
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
//| Trading-hours filter (server time)                               |
//+------------------------------------------------------------------+
bool TimeAllowed()
  {
   if(!InpUseTimeFilter)
      return true;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;
   if(InpStartHour <= InpEndHour)
      return (h >= InpStartHour && h < InpEndHour);
   return (h >= InpStartHour || h < InpEndHour);   // overnight wrap
  }

//+------------------------------------------------------------------+
//| Day-start equity snapshot (FTMO-style daily loss reference)      |
//| NOTE: if the EA is attached mid-day, the snapshot is taken at    |
//| attach time, not 00:00. Floating P/L counts toward the limit.    |
//+------------------------------------------------------------------+
void UpdateDayRef()
  {
   datetime dayStart = iTime(_Symbol, PERIOD_D1, 0);
   if(dayStart == 0)
      return;
   if(dayStart != dayRef)
     {
      dayRef         = dayStart;
      dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      Print("New trading day: day-start equity = ",
            DoubleToString(dayStartEquity, 2));
     }
  }

bool DailyLossHalted()
  {
   if(InpMaxDailyLossPct <= 0)
      return false;
   if(dayStartEquity <= 0)
      return false;
   double loss = dayStartEquity - AccountInfoDouble(ACCOUNT_EQUITY);
   return (loss >= (InpMaxDailyLossPct / 100.0) * dayStartEquity);
  }

//+------------------------------------------------------------------+
//| Manage open positions: zone-violation exits + fractal trailing   |
//+------------------------------------------------------------------+
void ManagePositions(double atr)
  {
   double tol      = InpTouchTolAtr * atr;
   double sigClose = iClose(_Symbol, PERIOD_H4, 1);   // last CLOSED H4 bar

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

      //--- 1) violation exit: H4 close beyond the entry zone
      if(ZoneViolated(cmt, tol, sigClose, ptype))
        {
         if(trade.PositionClose(ticket))
            Print("Closed #", ticket, ": entry zone violated by H4 close.");
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
//| Test the last closed H4 bar against the zone stored in the       |
//| position comment. Format: "SDA|D|<bot>|<top>" / "SDA|S|<bot>|<top>"|
//+------------------------------------------------------------------+
bool ZoneViolated(string cmt, double tol, double sigClose, long ptype)
  {
   string parts[];
   if(StringSplit(cmt, '|', parts) < 4)
      return false;
   if(parts[0] != InpTradeComment)
      return false;

   double bot = StringToDouble(parts[2]);
   double top = StringToDouble(parts[3]);
   if(bot <= 0 || top <= 0 || top <= bot || sigClose <= 0)
      return false;

   if(parts[1] == "D" && ptype == POSITION_TYPE_BUY && sigClose < bot - tol)
      return true;
   if(parts[1] == "S" && ptype == POSITION_TYPE_SELL && sigClose > top + tol)
      return true;
   return false;
  }

//+------------------------------------------------------------------+
//| Trail stop behind the most recent confirmed fractal swing        |
//+------------------------------------------------------------------+
void TrailPosition(ulong ticket, long ptype, double entry, double curSL,
                   double tp, double atr)
  {
   if(tp <= 0 || InpTpRMultiple <= 0)
      return;
   // original risk recovered from the TP set at entry (TP is never moved)
   double origRisk = MathAbs(tp - entry) / InpTpRMultiple;
   if(origRisk <= 0)
      return;

   double buf     = InpTrailBufferAtr * atr;
   double minDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(ptype == POSITION_TYPE_BUY)
     {
      if(bid - entry < InpTrailStartR * origRisk)
         return;                          // not yet 1R in profit
      double fl = LastFractalLow();
      if(fl <= 0)
         return;
      double newSL = NormalizeDouble(fl - buf, _Digits);
      if(newSL <= curSL)
         return;                          // only move up
      if(newSL >= bid - MathMax(minDist, _Point))
         return;                          // respect broker stop level
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
         return;                          // only move down
      if(newSL <= ask + MathMax(minDist, _Point))
         return;
      if(trade.PositionModify(ticket, newSL, tp))
         Print("Trailed #", ticket, " SL -> ", DoubleToString(newSL, _Digits));
     }
  }

//+------------------------------------------------------------------+
//| Most recent confirmed fractal swing low/high (lag = 2+ bars)     |
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
//| One trade per zone                                               |
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
   if(ArraySize(tradedKeys) > 500)        // cap memory
      ArrayRemove(tradedKeys, 0, ArraySize(tradedKeys) - 500);
  }

//+------------------------------------------------------------------+
//| On-chart status panel                                            |
//+------------------------------------------------------------------+
void DrawStatus()
  {
   double dayPL = (dayStartEquity > 0)
                  ? AccountInfoDouble(ACCOUNT_EQUITY) - dayStartEquity : 0;
   string s = StringFormat(
      "SupplyDemandAuto | %s H4\nMagic %I64d | Positions %d | Day P/L %.2f\nLive zones: %d",
      _Symbol, InpMagic, CountMyPositions(), dayPL, CountValidZones());
   if(DailyLossHalted())
      s += "\n!! DAILY LOSS LIMIT REACHED - no new entries today !!";
   Comment(s);
  }
//+------------------------------------------------------------------+
