# SupplyDemandAuto.mq5 — README

Fully automatic supply & demand Expert Advisor for **XAUUSD (gold)** on MetaTrader 5.
No manual drawing, no trendlines, no discretionary input once running.

## What it does

1. **Finds zones on the 4H chart.** Scans for strong impulsive moves away from a
   small-bodied base bar: rally-base-rally marks a **demand** zone, drop-base-drop
   marks a **supply** zone. The zone is the base bar's high/low range. Only impulses
   with a body of at least `InpImpulseAtr` x ATR(14) qualify, so minor noise is ignored.
2. **Enters on the 15M chart.** When price returns to a fresh, unmitigated zone, the EA
   takes the trade on confirmation from the just-closed M15 bar: a **rejection wick**
   (configurable minimum wick fraction) or an **engulfing candle** in the zone's
   direction. Demand = buy, supply = sell.
3. **Manages the trade.** Stop loss goes beyond the far edge of the zone plus an ATR
   buffer. Take profit defaults to **2R**. After 1R of profit, the stop optionally
   trails behind confirmed fractal swings. If a 4H candle **closes** beyond the entry
   zone, the trade is exited early (genuine mitigation, not a wick).
4. **Zone freshness rules.** A zone dies on the first entry taken from it (toggleable),
   on any 4H close beyond it, or after `InpZoneMaxAgeBars` H4 bars — whichever comes
   first. Dead zones are remembered and never re-detected.
5. **FTMO-style risk guards.** Fixed fractional risk per trade (default 1% of equity),
   max one open position per symbol, max spread filter, optional trading-hours filter,
   and a daily-loss circuit breaker (default 4% of day-start equity) that halts new
   entries for the rest of the day. No martingale, no grid, no averaging down.

## Install

1. In MT5: **File > Open Data Folder > MQL5 > Experts** — copy `SupplyDemandAuto.mq5` there.
2. Press **F4** to open MetaEditor, open the file, press **F7** to compile.
   Fix any errors before use (a clean compile shows 0 errors, 0 warnings ideally).
3. Drag the EA onto an **XAUUSD H4** chart.
4. Enable the **Algo Trading** button on the MT5 toolbar.
5. Live zones draw themselves as green (demand) / red (supply) rectangles prefixed `SDA_`.

## Recommended settings for XAUUSD on H4

The defaults are the recommended starting point:

- Zone Detection: impulse 2.0 ATR, base max 0.6 ATR, lookback 150 bars, max age 60 bars
- Entry: wick min 0.30 of range, engulfing ON
- Trade: SL buffer 0.5 ATR beyond zone edge, TP 2.0R
- Trailing: ON, start at 1.0R, 0.10 ATR buffer
- Risk: 1.0% per trade, max spread 40 points, daily loss halt 4%, max 1 position
- Trading hours: OFF by default (enable if you want to avoid Asian session, etc.)
- Magic number: 20261009 (change it if you run another EA on the same account/symbol)

## Demo-first warning

**This EA is untested and makes no profitability claim.** It automates a rule set; it does
not know whether the rule set is profitable. Forward-test on a **demo account** for several
weeks, across different market regimes (trend, range, high-volatility news weeks), before
even thinking about live capital. Start at 1% risk or less and review the Experts log —
every zone detection, entry, skip reason, and exit is printed there.

## What it does NOT do

- No breakout entries — it only trades bounces off fresh zones.
- No news filter — it will trade straight through high-impact news unless you enable the
  trading-hours filter or turn it off manually. Consider pausing it around FOMC, NFP, and CPI.
- No partial profits, no break-even move other than the fractal trail.
- No multi-timeframe trend filter — a demand zone inside a strong 4H downtrend will still
  trigger a buy. That is by design (pure S/D logic); add a trend filter only if forward
  testing says it helps.
- It cannot run on the MT5 phone/tablet app. EAs require desktop MT5 (Windows/Mac) or a
  Windows VPS running MT5.
- One position per symbol: while a trade is open, new zone signals are skipped.

## Files

- `SupplyDemandAuto.mq5` — the EA (this README's companion)
- Delete/ignore `TrendlineBounceManager.mq5` if present — that was the earlier
  semi-manual version (you drew the lines yourself). This EA replaces it.
