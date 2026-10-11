//+------------------------------------------------------------------+
//|                                       SupplyDemandDayTrade.mq5   |
//|                                        Deva Gana LLC - Brittany  |
//|                                                                  |
//| DAY-TRADING variant of SupplyDemandAuto. Same supply/demand      |
//| engine, adapted for intraday XAUUSD trading:                     |
//|  1. Zones detected on H1 (configurable), entries confirmed on    |
//|     M5. Smaller, faster zones than the swing version.            |
//|  2. FLAT AT END OF DAY: every open position is closed at the     |
//|     configured flat time (default 20:55 server time). No new     |
//|     entries after the entry cutoff (default 19:00 server).       |
//|     This EA NEVER holds a position overnight.                    |
//|  3. Session filter: London + New York sessions by default        |
//|     (configurable, server time).                                 |
//|  4. Tighter targets: 1.5R default TP, optional 50% partial at    |
//|     1R, remainder trailed behind entry-TF fractal swings.        |
//|  5. Max 3 new trades per day, one position at a time.            |
//|  6. Friday: no new entries after the cutoff, everything flat    |
//|     at the flat time - nothing carried into the weekend.         |
//|  7. FTMO-STYLE GUARDS: fixed fractional risk, max spread filter, |
//|     daily-loss circuit breaker (floating P/L counts).            |
//|                                                                  |
//| IMPORTANT                                                        |
//|  - This is an UNTESTED automation. It has no proven              |
//|    profitability. Forward-test on DEMO for several weeks across  |
//|    different market regimes before considering any live use.      |
//|  - No martingale, no grid, no averaging down. Fixed fractional   |
//|    risk only.                                                    |
//|  - ALL times are SERVER time. Check your broker's server clock   |
//|    (Market Watch clock in MT5) and adjust the session / cutoff / |
//|    flat inputs to match. A wrong flat time can leave positions   |
//|    open into rollover.                                           |
//|  - No news filter is built in. Pause the EA yourself around      |
//|    NFP, CPI and FOMC.                                            |
//|  - Attach to an XAUUSD H1 chart. The EA reads M5 data itself     |
//|    for entry confirmation.                                       |
//|                                                                  |
//| INSTALL                                                          |
//|  1. MT5 > File > Open Data Folder > MQL5 > Experts > paste this  |
//|     file.                                                        |
//|  2. Press F4 to open MetaEditor, open the file, press F7 to      |
//|     compile. Fix any errors before use.                          |
//|  3. Drag the EA onto an XAUUSD H1 chart.                         |
//|  4. Enable the "Algo Trading" button on the MT5 toolbar.         |
//+------------------------------------------------------------------+
#property copyright "Deva Gana LLC"
#property version   "1.00"
#property description "Intraday supply/demand EA for XAUUSD. Flat at EOD, no overnight holds. UNTESTED - demo forward-test required."

#include <Trade\Trade.mqh>

//--- inputs: zone detection
input group "Zone Detection"
input ENUM_TIMEFRAMES InpZoneTF      = PERIOD_H1; // Zone timeframe
input double InpImpulseAtr    = 2.0;    // Min impulse body to mark a zone (x ATR)
input double InpBaseMaxAtr     = 0.6;    // Max base-bar body (x ATR)
input int    InpBaseSearchBars = 3;      // Bars searched back for the base
input int    InpZoneLookback   = 150;    // Zone scan lookback (zone-TF bars)
input int    InpZoneMaxAgeBars = 24;     // Zone expiry (zone-TF bars)
input double InpTouchTolAtr    = 0.25;   // Zone touch tolerance (x ATR)
input double InpMitigTolAtr    = 0.25;   // Mitigation close tolerance (x ATR)
input bool   InpOneTapPerZone  = true;   // Retire zone after first entry

//--- inputs: entry confirmation
input group "Entry Confirmation"
input ENUM_TIMEFRAMES InpEntryTF   = PERIOD_M5; // Entry timeframe
input double InpWickMinFrac  = 0.30;    // Min rejection wick (fraction of range)
input bool   InpUseEngulfing = true;    // Also accept engulfing confirmation

//--- inputs: trade construction
input group "Trade Construction"
input double InpSlBufferAtr = 0.50;     // SL buffer beyond zone edge (x ATR)
input double InpTpRMultiple = 1.5;      // Take profit (R multiple)

//--- inputs: partial close + trailing
input group "Partial Close & Trailing"
input bool   InpUsePartial     = true;  // Take partial profit at +1R
input double InpPartialAtR     = 1.0;   // Partial trigger (R multiple)
input double InpPartialPct     = 50.0;  // Partial size (% of position)
input bool   InpUseTrailing    = true;  // Trail behind entry-TF fractal swings
input double InpTrailStartR    = 1.0;    // Start trailing at profit (R)
input double InpTrailBufferAtr = 0.10;  // Trail buffer behind fractal (x ATR)

//--- inputs: risk
input group "Risk Management"
input double InpRiskPct         = 1.0;  // Risk per trade (% of equity)
input int    InpMaxSpreadPoints = 40;   // Max spread filter (points)
input double InpMaxDailyLossPct = 4.0;  // Daily loss halt (% of day-start equity, 0=off)
input int    InpMaxPositions    = 1;    // Max open positions (this symbol+magic)
input int    InpMaxTradesPerDay = 3;    // Max NEW trades per day

//--- inputs: sessions + end-of-day flat (SERVER time)
input group "Sessions & End-of-Day Flat (SERVER time)"
input bool InpUseSessionFilter = true;  // Trade sessions only (London+NY default)
input int  InpSessionStartHour = 7;      // Session start hour (0-23)
input int  InpSessionStartMin  = 0;      // Session start minute (0-59)
input int  InpSessionEndHour   = 21;     // Session end hour (0-23)
input int  InpSessionEndMin    = 0;      // Session end minute (0-59)
input int  InpNoNewAfterHour   = 19;    // No new entries after, hour (0-23)
input int  InpNoNewAfterMin    = 0;      // No new entries after, minute (0-59)
input int  InpFlatHour         = 20;    // Flat time: close ALL positions, hour
input int  InpFlatMinute       = 55;    // Flat time: close ALL positions, minute

//--- inputs: general
input group "General"
input long   InpMagic        = 20261010; // Magic number (differs from swing EA)
input string InpTradeComment = "SDD";   // Trade comment prefix (keep short)
input bool   InpShowDeadZones = true;   // Draw retired zones in gray (visual only, no trade effect)

//--- structs
struct SDZone
  {
   datetime          t;                  // base bar time
   double            top;
   double            bot;
   bool              isDemand;
   bool              valid;
   string            note;               // visual label (e.g. retire reason)
  };

//--- globals
CTrade     trade;
int        atrHandle     = INVALID_HANDLE;
int        fractalHandle = INVALID_HANDLE;
datetime   lastZoneBar   = 0;
datetime   lastEntryBar  = 0;
bool       firstRun      = true;
SDZone     liveZones[];                 // tradeable zones
SDZone     deadZones[];                 // retired zones, drawn gray for visibility
datetime   deadTimes[];                 // base times of retired zones (never re-add)
string     tradedKeys[];                // "D|zoneTime|sigBar" already taken
ulong      partialTickets[];            // tickets already partially closed
datetime   dayRef        = 0;
double     dayStartEquity= 0;
int        tradesToday   = 0;
bool       flatDoneToday = false;
int        atrPeriod     = 14;

//+------------------------------------------------------------------+
bool ValidHM(int h, int m)
  {
   return (h >= 0 && h <= 23 && m >= 0 && m <= 59);
  }

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
   if(InpMaxPositions < 1 || InpMaxTradesPerDay < 1)
     {
      Print("InpMaxPositions and InpMaxTradesPerDay must be at least 1.");
      return INIT_FAILED;
     }
   if(InpUsePartial && (InpPartialPct <= 0 || InpPartialPct >= 100))
     {
      Print("InpPartialPct must be between 0 and 100 (exclusive).");
      return INIT_FAILED;
     }
   if(!ValidHM(InpSessionStartHour, InpSessionStartMin) ||
      !ValidHM(InpSessionEndHour,   InpSessionEndMin)   ||
      !ValidHM(InpNoNewAfterHour,   InpNoNewAfterMin)   ||
      !ValidHM(InpFlatHour,         InpFlatMinute))
     {
      Print("Session/cutoff/flat times must be valid hours (0-23) and minutes (0-59).");
      return INIT_FAILED;
     }
   if(InpMagic == 20261009)
     {
      Print("WARNING: magic 20261009 belongs to the swing EA (SupplyDemandAuto). ",
            "Use a different magic so the two EAs never manage each other's trades.");
     }
   if(InpEntryTF >= InpZoneTF)
      Print("WARNING: entry timeframe should be smaller than the zone timeframe.");

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   atrHandle     = iATR(_Symbol, InpZoneTF, atrPeriod);
   fractalHandle = iFractals(_Symbol, InpEntryTF);
   if(atrHandle == INVALID_HANDLE || fractalHandle == INVALID_HANDLE)
     {
      Print("Failed to create indicator handles.");
      return INIT_FAILED;
     }

   ArrayResize(liveZones, 0);
   ArrayResize(deadTimes, 0);
   ArrayResize(tradedKeys, 0);
   ArrayResize(partialTickets, 0);

   Print("SupplyDemandDayTrade initialized on ", _Symbol,
         " | Magic=", InpMagic,
         " | Zones=", EnumToString(InpZoneTF),
         " | Entry=", EnumToString(InpEntryTF),
         " | Risk=", DoubleToString(InpRiskPct, 2), "%",
         " | TP=", DoubleToString(InpTpRMultiple, 1), "R",
         " | Flat=", IntegerToString(InpFlatHour), ":",
         StringFormat("%02d", InpFlatMinute), " server");
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

   UpdateDayRef();          // new-day resets: counters, flat flag, equity snapshot
   CheckFlatTime();         // hard EOD flat - runs on every tick, cheap

   bool newZone  = IsNewBarTF(InpZoneTF,  lastZoneBar);
   bool newEntry = IsNewBarTF(InpEntryTF, lastEntryBar);
   if(!newZone && !newEntry && !firstRun)
      return;
   firstRun = false;

   double atr = GetATR(1);               // last CLOSED zone-TF bar ATR (no repaint)
   if(atr <= 0)
      return;

   if(newZone)
      UpdateZones(atr);                 // age/mitigation + detect new, redraw
   if(newEntry || newZone)
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
//| ATR value at shift (zone timeframe)                              |
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
   double violTol   = InpMitigTolAtr * atr;
   double zoneSecs  = (double)PeriodSeconds(InpZoneTF);
   double maxAgeSec = (double)InpZoneMaxAgeBars * zoneSecs;
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

      // mitigation: any zone-TF close beyond the far edge since formation
      int idx = iBarShift(_Symbol, InpZoneTF, liveZones[i].t);
      if(idx < 1)
         continue;                        // base bar not in history; keep
      if(idx > InpZoneLookback + 20)
         idx = InpZoneLookback + 20;

      bool mitigated = false;
      for(int b = 1; b <= idx; b++)
        {
         double c = iClose(_Symbol, InpZoneTF, b);
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
   // keep a visual copy so the chart shows what was considered and why
   SDZone dz = liveZones[i];
   dz.valid = false;
   dz.note  = reason;
   int n = ArraySize(deadZones);
   ArrayResize(deadZones, n + 1);
   deadZones[n] = dz;
   if(ArraySize(deadZones) > 30)
      ArrayRemove(deadZones, 0, ArraySize(deadZones) - 30);
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
//| Detect new zones from impulsive zone-TF moves                    |
//+------------------------------------------------------------------+
void DetectNewZones(double atr)
  {
   int n = InpZoneLookback + 5;
   double oo[], hh[], ll[], cc[];
   datetime tt[];
   if(CopyOpen(_Symbol, InpZoneTF, 0, n, oo) < n)  return;
   if(CopyHigh(_Symbol, InpZoneTF, 0, n, hh) < n)  return;
   if(CopyLow(_Symbol, InpZoneTF, 0, n, ll) < n)   return;
   if(CopyClose(_Symbol, InpZoneTF, 0, n, cc) < n) return;
   if(CopyTime(_Symbol, InpZoneTF, 0, n, tt) < n)  return;

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
   double zoneSecs = (double)PeriodSeconds(InpZoneTF);
   for(int i = 0; i < ArraySize(liveZones); i++)
     {
      if(!liveZones[i].valid)
         continue;
      if(liveZones[i].isDemand != cand.isDemand)
         continue;
      double dtSec = MathAbs((double)(liveZones[i].t - cand.t));
      if(dtSec > 5 * zoneSecs)
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
   double zoneSecs = (double)PeriodSeconds(InpZoneTF);
   int drawn = 0;
   for(int i = 0; i < ArraySize(liveZones); i++)
     {
      if(!liveZones[i].valid)
         continue;
      string name = "SDD_Z" + IntegerToString(drawn);
      datetime t2 = TimeCurrent() + (datetime)(20 * zoneSecs);
      if(!ObjectCreate(0, name, OBJ_RECTANGLE, 0,
                       liveZones[i].t, liveZones[i].top, t2, liveZones[i].bot))
         continue;
      ObjectSetInteger(0, name, OBJPROP_FILL, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      color c = liveZones[i].isDemand ? C'0,150,0' : C'180,0,0';
      ObjectSetInteger(0, name, OBJPROP_COLOR, c);
      ObjectSetString(0, name, OBJPROP_TEXT,
                      liveZones[i].isDemand ? "SDD demand" : "SDD supply");
      drawn++;
     }
   //--- retired zones: gray, labeled with the retire reason (visual only)
   if(InpShowDeadZones)
     {
      for(int i = 0; i < ArraySize(deadZones); i++)
        {
         string dname = "SDD_D" + IntegerToString(i);
         datetime dt2 = TimeCurrent() + (datetime)(20 * zoneSecs);
         if(!ObjectCreate(0, dname, OBJ_RECTANGLE, 0,
                          deadZones[i].t, deadZones[i].top, dt2, deadZones[i].bot))
            continue;
         ObjectSetInteger(0, dname, OBJPROP_FILL, true);
         ObjectSetInteger(0, dname, OBJPROP_BACK, true);
         ObjectSetInteger(0, dname, OBJPROP_COLOR, C'150,150,150');
         ObjectSetInteger(0, dname, OBJPROP_STYLE, STYLE_DOT);
         ObjectSetString(0, dname, OBJPROP_TEXT,
                         "retired: " + deadZones[i].note);
        }
     }
   ChartRedraw();
  }

void DeleteMyObjects()
  {
   for(int i = ObjectsTotal(0) - 1; i >= 0; i--)
     {
      string name = ObjectName(0, i);
      if(StringFind(name, "SDD_") == 0)
         ObjectDelete(0, name);
     }
  }

//+------------------------------------------------------------------+
//| Check for entries on fresh entry-TF / zone-TF bars               |
//+------------------------------------------------------------------+
void CheckEntries(double atr)
  {
   if(CountValidZones() == 0)
      return;
   if(!EntryGatesPass())
      return;

   double tol = InpTouchTolAtr * atr;
   datetime sigBar = iTime(_Symbol, InpEntryTF, 1);   // just-closed entry bar

   for(int i = ArraySize(liveZones) - 1; i >= 0; i--)   // newest first
     {
      if(!liveZones[i].valid)
         continue;
      string key = (liveZones[i].isDemand ? "D|" : "S|") +
                   IntegerToString((long)liveZones[i].t) + "|" +
                   IntegerToString((long)sigBar);
      if(AlreadyTraded(key))
         continue;

      if(liveZones[i].isDemand)
         TryDemandEntry(i, tol, atr, key);
      else
         TrySupplyEntry(i, tol, atr, key);

      if(CountMyPositions() >= InpMaxPositions)
         break;                          // one position at a time
     }
  }

//+------------------------------------------------------------------+
//| All pre-entry gates (day-trade specific)                         |
//+------------------------------------------------------------------+
bool EntryGatesPass()
  {
   if(CountMyPositions() >= InpMaxPositions)
      return false;

   if(tradesToday >= InpMaxTradesPerDay)
      return false;                       // daily trade budget spent

   if(flatDoneToday)
      return false;                       // already flattened for the day

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

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == 0 || dt.day_of_week == 6)
      return false;                       // weekend: market closed anyway

   if(!SessionAllowed(dt))
     {
      return false;                       // outside London/NY sessions
     }

   if(EntryCutoffPassed(dt))
     {
      return false;                       // too close to the EOD flat
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Session filter (server time)                                     |
//+------------------------------------------------------------------+
bool SessionAllowed(const MqlDateTime &dt)
  {
   if(!InpUseSessionFilter)
      return true;
   int nowM   = dt.hour * 60 + dt.min;
   int startM = InpSessionStartHour * 60 + InpSessionStartMin;
   int endM   = InpSessionEndHour * 60 + InpSessionEndMin;
   if(startM <= endM)
      return (nowM >= startM && nowM < endM);
   return (nowM >= startM || nowM < endM);   // overnight wrap
  }

//+------------------------------------------------------------------+
//| No new entries after the cutoff (server time)                    |
//+------------------------------------------------------------------+
bool EntryCutoffPassed(const MqlDateTime &dt)
  {
   int nowM    = dt.hour * 60 + dt.min;
   int cutM    = InpNoNewAfterHour * 60 + InpNoNewAfterMin;
   return (nowM >= cutM);
  }

//+------------------------------------------------------------------+
//| Demand entry: entry-TF bar tapped the zone and confirmed bullish |
//+------------------------------------------------------------------+
void TryDemandEntry(int zi, double tol, double atr, string key)
  {
   double o = iOpen(_Symbol, InpEntryTF, 1);
   double h = iHigh(_Symbol, InpEntryTF, 1);
   double l = iLow(_Symbol, InpEntryTF, 1);
   double c = iClose(_Symbol, InpEntryTF, 1);
   if(o <= 0 || h <= 0 || l <= 0 || c <= 0)
      return;

   double top = liveZones[zi].top;
   double bot = liveZones[zi].bot;

   // closed through the zone on the entry TF: zone is dead immediately
   if(c < bot - tol)
     {
      RetireZone(zi, "entry-TF close-through");
      DrawZones();
      return;
     }

   // must have entered the zone
   if(l > top + tol)
      return;

   bool confirmed = BullishReject(o, h, l, c);
   if(!confirmed && InpUseEngulfing)
      confirmed = BullishEngulf(InpEntryTF);

   if(confirmed)
      OpenZoneTrade(true, zi, atr, key);
  }

//+------------------------------------------------------------------+
//| Supply entry: mirror image                                       |
//+------------------------------------------------------------------+
void TrySupplyEntry(int zi, double tol, double atr, string key)
  {
   double o = iOpen(_Symbol, InpEntryTF, 1);
   double h = iHigh(_Symbol, InpEntryTF, 1);
   double l = iLow(_Symbol, InpEntryTF, 1);
   double c = iClose(_Symbol, InpEntryTF, 1);
   if(o <= 0 || h <= 0 || l <= 0 || c <= 0)
      return;

   double top = liveZones[zi].top;
   double bot = liveZones[zi].bot;

   if(c > top + tol)
     {
      RetireZone(zi, "entry-TF close-through");
      DrawZones();
      return;
     }

   if(h < bot - tol)
      return;

   bool confirmed = BearishReject(o, h, l, c);
   if(!confirmed && InpUseEngulfing)
      confirmed = BearishEngulf(InpEntryTF);

   if(confirmed)
      OpenZoneTrade(false, zi, atr, key);
  }

//+------------------------------------------------------------------+
//| Confirmation patterns (entry TF, just-closed bar)                |
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

bool BullishEngulf(ENUM_TIMEFRAMES tf)
  {
   double o1 = iOpen(_Symbol, tf, 1);
   double c1 = iClose(_Symbol, tf, 1);
   double o2 = iOpen(_Symbol, tf, 2);
   double c2 = iClose(_Symbol, tf, 2);
   if(o1 <= 0 || c1 <= 0 || o2 <= 0 || c2 <= 0)
      return false;
   if(!(c1 > o1))
      return false;                       // current bar bullish
   if(!(c1 > o2 && o1 < c2))
      return false;                       // body engulfs prior body
   return true;
  }

bool BearishEngulf(ENUM_TIMEFRAMES tf)
  {
   double o1 = iOpen(_Symbol, tf, 1);
   double c1 = iClose(_Symbol, tf, 1);
   double o2 = iOpen(_Symbol, tf, 2);
   double c2 = iClose(_Symbol, tf, 2);
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
      tradesToday++;
      if(InpOneTapPerZone)
        {
         RetireZone(zi, "first tap traded");
         DrawZones();
        }
      Print((isBuy ? "BUY " : "SELL "), DoubleToString(lots, 2),
            " ", _Symbol, " @", DoubleToString(price, _Digits),
            " SL=", DoubleToString(sl, _Digits),
            " TP=", DoubleToString(tp, _Digits),
            " [", (isBuy ? "demand" : "supply"), " zone]",
            " | trade #", tradesToday, " today");
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
//| Day-start equity snapshot + daily counter resets                 |
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
      tradesToday    = 0;
      flatDoneToday  = false;
      ArrayResize(partialTickets, 0);
      Print("New trading day: day-start equity = ",
            DoubleToString(dayStartEquity, 2),
            " | trade budget reset to ", InpMaxTradesPerDay);
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
//| Hard end-of-day flat: close EVERYTHING of ours at the flat time  |
//| Runs on every tick (cheap) so the flat is never missed.          |
//+------------------------------------------------------------------+
void CheckFlatTime()
  {
   if(flatDoneToday)
      return;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int nowM  = dt.hour * 60 + dt.min;
   int flatM = InpFlatHour * 60 + InpFlatMinute;
   if(nowM >= flatM)
     {
      CloseAllMine("end-of-day flat");
      flatDoneToday = true;
      Print("EOD flat executed at server ",
            IntegerToString(dt.hour), ":", StringFormat("%02d", dt.min),
            ". No new entries until tomorrow.");
     }
  }

//+------------------------------------------------------------------+
//| Close all our positions on this symbol                           |
//+------------------------------------------------------------------+
void CloseAllMine(string reason)
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
      if(trade.PositionClose(ticket))
         Print("Closed #", ticket, " (", reason, ").");
      else
         Print("Close failed #", ticket, ": ", trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| Manage open positions: violation exits, partial, trailing        |
//+------------------------------------------------------------------+
void ManagePositions(double atr)
  {
   double tol      = InpTouchTolAtr * atr;
   double sigClose = iClose(_Symbol, InpZoneTF, 1);   // last CLOSED zone-TF bar

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

      //--- 1) violation exit: zone-TF close beyond the entry zone
      if(ZoneViolated(cmt, tol, sigClose, ptype))
        {
         if(trade.PositionClose(ticket))
            Print("Closed #", ticket, ": entry zone violated by zone-TF close.");
         else
            Print("Close failed #", ticket, ": ", trade.ResultRetcodeDescription());
         continue;
        }

      //--- 2) partial profit at +1R
      MaybePartialClose(ticket, ptype, entry);

      //--- 3) fractal trailing stop on the remainder
      if(InpUseTrailing)
         TrailPosition(ticket, ptype, entry, curSL, tp, atr);
     }
  }

//+------------------------------------------------------------------+
//| Test the last closed zone-TF bar against the zone in the comment |
//| Format: "SDD|D|<bot>|<top>" / "SDD|S|<bot>|<top>"                |
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
//| Partial close: take InpPartialPct% off at +InpPartialAtR         |
//+------------------------------------------------------------------+
void MaybePartialClose(ulong ticket, long ptype, double entry)
  {
   if(!InpUsePartial)
      return;
   if(PartialDone(ticket))
      return;

   double tp = PositionGetDouble(POSITION_TP);
   if(tp <= 0 || InpTpRMultiple <= 0)
      return;
   // original risk recovered from the TP set at entry (TP is never moved)
   double origRisk = MathAbs(tp - entry) / InpTpRMultiple;
   if(origRisk <= 0)
      return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double profit = (ptype == POSITION_TYPE_BUY) ? bid - entry : entry - ask;
   if(profit < InpPartialAtR * origRisk)
      return;                             // not yet at the partial trigger

   double vol    = PositionGetDouble(POSITION_VOLUME);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0 || vol <= 0)
      return;

   double closeVol = MathFloor((vol * InpPartialPct / 100.0) / step) * step;
   double remain   = vol - closeVol;
   if(closeVol < minLot || remain < minLot)
     {
      Print("Partial skipped #", ticket,
            ": closing ", DoubleToString(closeVol, 2),
            " would leave ", DoubleToString(remain, 2),
            " (min lot ", DoubleToString(minLot, 2), ").");
      return;
     }

   if(trade.PositionClosePartial(ticket, closeVol))
     {
      MarkPartialDone(ticket);
      Print("Partial #", ticket, ": closed ", DoubleToString(closeVol, 2),
            " lots at +", DoubleToString(InpPartialAtR, 1),
            "R, ", DoubleToString(remain, 2), " running.");
     }
   else
      Print("Partial failed #", ticket, ": ", trade.ResultRetcodeDescription());
  }

bool PartialDone(ulong ticket)
  {
   for(int i = 0; i < ArraySize(partialTickets); i++)
      if(partialTickets[i] == ticket)
         return true;
   return false;
  }

void MarkPartialDone(ulong ticket)
  {
   int n = ArraySize(partialTickets);
   ArrayResize(partialTickets, n + 1);
   partialTickets[n] = ticket;
   if(ArraySize(partialTickets) > 100)
      ArrayRemove(partialTickets, 0, ArraySize(partialTickets) - 100);
  }

//+------------------------------------------------------------------+
//| Trail stop behind the most recent confirmed fractal swing        |
//| (entry timeframe; lag = 2+ bars)                                 |
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
         return;                          // not yet at trail start
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
//| Most recent confirmed fractal swing low/high (entry TF)          |
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
//| One trade per zone per signal bar                                |
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
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string s = StringFormat(
      "SupplyDemandDayTrade | %s zones %s / entry %s\nMagic %I64d | Positions %d | Trades today %d/%d | Day P/L %.2f\nLive zones: %d | Flat %02d:%02d server | Session %s",
      _Symbol, EnumToString(InpZoneTF), EnumToString(InpEntryTF),
      InpMagic, CountMyPositions(), tradesToday, InpMaxTradesPerDay, dayPL,
      CountValidZones(), InpFlatHour, InpFlatMinute,
      SessionAllowed(dt) ? "OPEN" : "CLOSED");
   if(DailyLossHalted())
      s += "\n!! DAILY LOSS LIMIT REACHED - no new entries today !!";
   if(flatDoneToday)
      s += "\nFlattened for the day - see you tomorrow.";
   if(!DailyLossHalted() && !flatDoneToday)
     {
      // plain-English reason for "why no trade right now"
      string why;
      if(!SessionAllowed(dt))
         why = "session closed (server time outside 07:00-21:00)";
      else if(tradesToday >= InpMaxTradesPerDay)
         why = "max trades reached for today";
      else if(CountValidZones() == 0)
         why = "no fresh zones in lookback - EA is scanning";
      else if(CountMyPositions() > 0)
         why = "managing open position";
      else
         why = "zones live - waiting for price to tap + M5 confirmation";
      s += "\nWaiting: " + why;
     }
   Comment(s);
  }
//+------------------------------------------------------------------+
