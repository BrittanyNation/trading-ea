# SupplyDemandDayTrade — Intraday Supply & Demand EA for XAUUSD

Day-trading variant of `SupplyDemandAuto.mq5`. Same supply/demand engine,
rebuilt for in-and-out-the-same-day gold trading. **UNTESTED — forward-test
on DEMO for several weeks before considering any live use. No profitability
is claimed or implied.**

## Install

1. MT5 > File > Open Data Folder > MQL5 > Experts > paste
   `SupplyDemandDayTrade.mq5` in.
2. Press F4 (MetaEditor), open the file, press F7 to compile. Fix any
   errors before use.
3. Drag the EA onto an **XAUUSD H1** chart.
4. Enable the **Algo Trading** button on the MT5 toolbar.
5. Your computer must stay on with MT5 open for the EA to trade. If the
   laptop sleeps or MT5 closes, the EA stops.

## How it differs from the swing version (SupplyDemandAuto)

| | Swing (SupplyDemandAuto) | Day trade (this EA) |
|---|---|---|
| Zone timeframe | H4 | H1 (configurable) |
| Entry confirmation | M15 | M5 (configurable) |
| Default target | 2R | 1.5R |
| Partial profit | No | Yes: 50% off at +1R, rest trailed |
| Holds overnight | Yes | **Never** — flat at 20:55 server |
| New entries after | n/a (optional hours filter) | Blocked after 19:00 server |
| Session filter | Optional, off by default | On: London + New York only |
| Trades per day | Unlimited (1 at a time) | Max 3 new trades/day |
| Friday | Trades normally | No entries after cutoff, flat EOD |
| Magic number | 20261009 | **20261010** (different on purpose) |
| Chart objects prefix | SDA_ | SDD_ |

The two EAs can run on the same account at once (different magics), but
think twice before doing that — they can end up holding opposite
directions on the same symbol.

## Strategy in plain English

1. On the H1 chart it finds supply/demand zones from strong impulsive
   moves away from a small base (rally-base-rally = demand,
   drop-base-drop = supply).
2. When price returns to a fresh zone, it waits for M5 confirmation: a
   rejection wick or an engulfing candle. Demand = buy, supply = sell.
3. Stop goes behind the far edge of the zone plus a 0.5x ATR buffer.
   Target is 1.5R.
4. At +1R it closes half the position and trails the rest behind M5
   fractal swings.
5. A zone dies after one trade, after price closes through it, or after
   24 H1 bars — whichever comes first.

## Sessions, cutoff, and flat time — READ THIS

**All times are your broker's SERVER time**, not your local time. Check
the clock in MT5's Market Watch panel — most brokers run GMT+2 or GMT+3.

- **Session filter (default 07:00–21:00 server):** entries only during
  London + New York. Gold is choppiest in the Asian session, so it's
  skipped by default. Turn `InpUseSessionFilter` off if you want all-day
  entries.
- **Entry cutoff (default 19:00 server):** no new trades after this.
  Gives open trades room to work before the flat.
- **Flat time (default 20:55 server):** every open position from this EA
  is market-closed, no exceptions. Set this 30–60 minutes BEFORE your
  broker's daily rollover/close, and check what time your broker closes
  on **Friday** — if their Friday close is earlier than 20:55, lower the
  flat time or positions may be force-closed by the broker instead.

## Recommended starting settings (XAUUSD)

Defaults are already tuned for this: H1 zones, M5 entries, 1% risk,
1.5R target, 50% partial at 1R, 3 trades/day max, 4% daily-loss halt.
The main things you may want to adjust per broker:

- `InpSessionStartHour` / `InpSessionEndHour` — match to your server clock
- `InpNoNewAfterHour` / `InpFlatHour` / `InpFlatMinute` — match to your
  broker's rollover and Friday close
- `InpMaxSpreadPoints` — gold spreads widen at rollover and news; 40 is
  conservative

## Warnings

- **Demo first.** Weeks, not days. Watch how it behaves around news.
- **No news filter.** Pause the EA yourself around NFP, CPI, FOMC. On an
  FTMO account, opening/closing within 2 minutes of major news can breach
  their rules.
- **US traders on FTMO:** FTMO puts US residents on DXtrade, where MT5
  EAs cannot run. Confirm platform with FTMO before buying a challenge.
- **One position at a time** (`InpMaxPositions = 1`). A second setup is
  ignored while a trade is open.
- **The daily-loss halt (4%)** counts floating P/L and uses the equity
  at the first tick of the day (or at attach time if attached mid-day),
  FTMO-style.
- Partial close needs enough volume: if closing 50% would leave less
  than the broker's minimum lot, the partial is skipped and the full
  position keeps running to the trailing stop or TP.
