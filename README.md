# Trading EA — Deva Gana LLC (private)

MT5 expert advisors and TradingView indicators for XAUUSD supply-and-demand trading. **Demo only — no live money until the evaluation gates pass.**

## Design rule

The EAs trade only what Brittany would trade manually: pure supply/demand price action plus risk rules. The trend EMA filter and volatility-spike guard exist in the scalp EA as toggles, default OFF.

## Files

- `experts/SupplyDemandScalp.mq5` — main EA: XAUUSD supply-and-demand, 4H zones, 15m entries, 1% risk per trade, one position, 4% daily stop. Install via MQL5/Experts, Algo Trading on.
- `experts/SupplyDemandAuto.mq5` — earlier auto variant.
- `experts/SupplyDemandDayTrade.mq5` — day-trade variant.
- `experts/TrendlineBounceManager.mq5` — trendline bounce manager.
- `pine/trendline_bounce.pine` — TradingView bounce indicator (Pine v6).
- `pine/supply_demand_zones.pine` — TradingView supply/demand zone indicator (Pine v6).
- `pine/trendline_supply_demand_toolkit.pine` — combined toolkit.
- `docs/EA_Evaluation_Tracker.xlsx` — evaluation tracker (gates, stats).
- `docs/EA_Trade_Journal.xlsx` — trade journal.
- `docs/EA_Rollout_Brief.md` — rollout brief.

## Evaluation gates (all must pass before live)

1. Compiles without errors.
2. Broker server time and XAUUSD symbol details verified.
3. At least 50 demo trades completed.
4. Win rate, profit factor, drawdown, expectancy, and rule compliance reviewed.

## Brokers

FTMO + OANDA (both free trials). Primary symbol XAUUSD, sometimes NAS100. 4H + 15m charts; bounce setups preferred.
