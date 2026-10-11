# EA Rollout Brief: which bot first, honest timelines, this-weekend setup

Built 2026-10-10. Companion to `EA_Evaluation_Tracker.xlsx` (which holds the Test Plan checklist, the 50-trade log, and the Review formulas). This brief answers the three questions the tracker does not: which EA to test first, how long a verdict actually takes, and what to do this weekend while markets are closed.

## The three EAs and how fast each gives you a verdict

| EA | Zones / entries | Target | Max trades/day | Realistic pace | Time to 50 trades |
|---|---|---|---|---|---|
| SupplyDemandScalp | M15 / M1 | 1.0R, 50% off at 0.5R | 8, London+NY sessions | 2-5/day in normal markets | 2-4 weeks |
| SupplyDemandDayTrade | H1 / M5 | 1.5R, 50% off at 1R | 3, London+NY only, flat EOD | 1-2/day | 5-10 weeks |
| SupplyDemandAuto (swing) | H4 / M15 | 2R | 1 at a time, holds overnight | 1-3/week | 4-6 months |

Start with the Scalp EA. It is the one the tracker was built around, it gives the fastest verdict, and it never holds a position overnight (flat 20:55 server time). The swing EA is the slowest path to an answer; run it only after the scalp has a verdict.

Honest framing: 50 demo trades is the minimum before any verdict, and that is 2-4 weeks for the scalp, longer for the others. A demo verdict is not a live-income plan. It is a filter that tells you which bot, if any, deserves a funded trial later.

## This weekend (markets closed): setup only

Gold is closed Saturday and reopens Sunday evening. Do the setup this weekend so the EA is live the moment markets open.

1. Pick the account FIRST. Critical check: FTMO puts US residents on DXtrade, and MT5 EAs cannot run there. Open MT5 and try logging in with the FTMO trial credentials. If MT5 rejects them, FTMO is not your platform; use the OANDA MT5 demo instead. This one check decides everything.
2. Install: MT5 > File > Open Data Folder > MQL5 > Experts > paste `SupplyDemandScalp.mq5`. Press F4 for MetaEditor, open the file, press F7 to compile. Zero errors before proceeding.
3. Read the broker's server clock (the clock at the top of the Market Watch panel). Write it down next to your local time. The EA's session filter, entry cutoff (19:00), and flat time (20:55) are all SERVER time, not your time.
4. Leave risk at 1% per trade (the default). One position at a time, 30-point spread filter, 3% daily-loss halt: these are already in the code.
5. Sunday evening: drag the EA onto an XAUUSD M15 chart, turn the Algo Trading button ON, and keep the computer on with MT5 open. The EA cannot run on the phone or tablet app. If the computer sleeps, the EA stops.
6. Log every trade in the tracker. The Review sheet computes win rate and profit factor automatically after 50 trades.

## Calendar hazard inside the test window

FOMC meets October 27-28 (rate decision Oct 28, 2:00 PM ET). The September meeting hiked to 3.75-4.00%, and most officials expect one more hike this year, so this one can move gold hard. The EAs have no news filter. Plan: pause the EA on Oct 27-28, or at minimum mark those two days as noise in the trade log. Same caution for NFP (first Friday of each month; next is Nov 6) and CPI releases.

## Rules for the test (do not change inputs mid-run)

Pure supply/demand price action plus the risk rules, exactly as she trades manually. The trend EMA filter and volatility-spike guard are OFF by default; keep them off until the first 50-trade verdict.

Verdict rules (matching the tracker): after 50 trades, profit factor above 1.2 with the risk guards intact is a pass worth a second 50-trade run; below 1.0 is a fail; between is inconclusive and needs more trades, not more tweaks.
