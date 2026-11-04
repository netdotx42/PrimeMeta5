# PrimeMeta5

Expert Advisor for a PrimeXBT MT5 Standard account: H4 EMA(50)/EMA(200) trend, M30 EMA(20) pullback, swing stop, 2R target, and equity-based sizing. Version **1.41**. The entry rules are the v1.30 rules. Risk controls are in [CHANGELOG.md](CHANGELOG.md).

Leveraged crypto CFDs can wipe out a deposit. Nothing here is a promise of profit, a backtest, or a recommendation to trade. Read [docs/AUDIT.md](docs/AUDIT.md) before attaching this to a live account. The 0.5% input is the risk of **one** position. `MaxTotalRiskPercent` (default 2) is the sum of stop-risk this terminal will add to, and `MaxOpenPositions` (default 4) is how many of this magic may be open. The 2% daily figure, on this terminal only, closes every symbol that uses this magic when `CloseAllMagicOnDailyLock` is true. It is not a guaranteed cap on loss, and a second terminal does not see the lock.

The owner has not chosen a licence. [LICENSE](LICENSE) is a placeholder, not a grant of rights.

## What it does

On each new M30 bar the EA evaluates the last **closed** H4 and M30 candles:

- Trend is up when H4 EMA 50 is above H4 EMA 200, and down when it is below. The forming H4 bar is not used.
- A long needs a bullish M30 candle that traded at or through EMA 20, closed back above it, and closed above the prior M30 high. A short is the mirror image.
- The stop sits beyond the recent M30 swing, padded by the larger of 10 points and 0.20 × M30 ATR(14). The target is 2R from the fill price used for the calculation.
- Volume is the largest step-aligned size whose stop loss, estimated by `OrderCalcProfit` for one lot plus `ExtraCostPerLot`, stays within `RiskPercent` of equity. The minimum lot is refused when it would exceed that budget.
- A new order is skipped when the spread is wide relative to ATR, ATR itself is outside the configured band, the stop is more than 5 × ATR, the stop or target violates the symbol stop level, margin would exceed 30% of equity or free margin, this symbol already has a position, the open-position count or total stop-risk cap would be exceeded, or the terminal is not allowed to trade. A bar whose indicators are not ready is retried until `MaxEntryDelaySeconds`, then skipped and logged.
- A shared daily equity baseline and a lock live in terminal global variables, keyed by account login and broker-server date. One chart publishes the baseline, and a non-positive value is discarded instead of being treated as a lock. With `ExcludeNonTradeCashflows` on, balance, credit, bonus, and correction deals are taken out of the comparison. Floating profit and swap still count. At a 2% drawdown the EA closes every open position with this magic on this terminal, and blocks new entries until the next server day.
- The default symbol list is `BTCUSDT`, `ETHUSDT`, `SOLUSDT`, `BNBUSDT`. `BASE` is intentionally absent. There is no session filter and no end-of-day close unless you turn that input on.

The chart timeframe can be anything. Indicators are requested on H4 and M30 explicitly. One instance per symbol.

The owner's original note is preserved as [docs/PRIMEXBT_STANDARD_README.txt](docs/PRIMEXBT_STANDARD_README.txt).

## Inputs

Defaults are the values in the source.

| Input | Default | Meaning |
| --- | --- | --- |
| `RiskPercent` | `0.5` | Equity percent risked on the stop of one new position. |
| `RestrictToPrimeXBTStandardSymbols` | `true` | `INIT_FAILED` unless `_Symbol` is on the allowlist. |
| `RequirePrimeXBTServerName` | `false` | Optional case-insensitive substring check for `prime` or `pxbt` in the server or company string. Leave off until you have read the real server name. |
| `AllowedCryptoSymbols` | `BTCUSDT,ETHUSDT,SOLUSDT,BNBUSDT` | Exact Market Watch names, comma-separated. Case-sensitive. |
| `RewardRisk` | `2.0` | Take-profit distance divided by stop distance. |
| `TrendFastEMA` | `50` | H4 fast EMA period. |
| `TrendSlowEMA` | `200` | H4 slow EMA period. Must be greater than the fast period. |
| `EntryEMA` | `20` | M30 pullback EMA period. |
| `SwingLookback` | `5` | Closed M30 bars included in the swing stop. Minimum 2. |
| `StopBufferPoints` | `10` | Extra stop distance in points. Compared with the ATR pad. |
| `MagicNumber` | `4260926` | Magic on orders and the filter for closes. |
| `DeviationPoints` | `20` | Maximum deviation, in points, passed to `CTrade`. |
| `UseATRStopBuffer` | `true` | Pad the stop by `ATRBufferMultiple` × ATR when that pad is larger than the point pad. |
| `ATRPeriod` | `14` | M30 ATR period. |
| `ATRBufferMultiple` | `0.20` | ATR stop pad. |
| `MinATRPercent` | `0.10` | Skip when ATR is below this percent of the last M30 close. `0` disables. |
| `MaxATRPercent` | `8.00` | Skip when ATR is above this percent of that close. `0` disables. |
| `MaxSpreadATRRatio` | `0.10` | Skip when the live spread is wider than this multiple of ATR. `0` disables. |
| `MaxStopATRMultiple` | `5.0` | Skip when the stop is farther than this multiple of ATR. `0` disables. |
| `RequireH4PriceSide` | `false` | Also require the last closed H4 close to be on the trend side of the fast EMA. |
| `EnableMarginCheck` | `true` | Reject the order when margin exceeds the cap or free margin. |
| `MaxMarginEquityPercent` | `30.0` | Per-order margin cap, as a percent of equity. |
| `AllowBuy` | `true` | Allow long entries. |
| `AllowSell` | `true` | Allow short entries. |
| `MaxSpreadPoints` | `0` | Spread cap in points. `0` disables. The ATR spread filter stays available. |
| `EnableNewEntries` | `true` | When false, entries stop. The daily closer and the optional end-of-day closer still run. |
| `DailyLossLimitPercent` | `2.0` | Drawdown from the daily equity baseline that locks entries and starts closes. `0` disables the check. The baseline global variable is still created in `OnInit`. |
| `EnableNewsFilter` | `false` | Block entries around high-importance calendar events. Bypassed in the Strategy Tester. |
| `NewsCurrencies` | `USD,EUR,GBP` | Currencies passed to the economic calendar. |
| `NewsMinutesBefore` | `30` | Minutes before an event that still block an entry. |
| `NewsMinutesAfter` | `30` | Minutes after an event that still block an entry. |
| `EnableEndOfDayClose` | `false` | Flatten this EA's positions on this symbol after the server-time cutoff, and block entries. |
| `CloseHour` | `23` | End-of-day hour, broker server time from `TimeCurrent`. |
| `CloseMinute` | `45` | End-of-day minute. |
| `MaxEntryDelaySeconds` | `20` | After a new M30 bar opens, retry while history or the trade server is not ready. Then skip that bar and log it. `0` to `1800`. |
| `MaxOpenPositions` | `4` | Maximum open positions with this magic, on all symbols, in this terminal. `0` disables the count. |
| `MaxTotalRiskPercent` | `2.0` | Cap on stop-risk already open plus the new trade, as a percent of equity. `0` disables. The default allows four 0.5% positions. |
| `ExtraCostPerLot` | `0.0` | Account-currency commission plus fee for 1.0 lot, added to the stop loss used for sizing. Swap is not included. `0` keeps price-only sizing. |
| `ExcludeNonTradeCashflows` | `true` | Remove balance, credit, bonus, and correction deals from the daily-loss comparison. Floating PnL and swap still count. |
| `CloseAllMagicOnDailyLock` | `true` | When the daily lock trips, every live chart closes all symbols with this magic. Other terminals are not affected. |
| `VerifyStopsAfterFill` | `true` | If a position with this magic on this symbol has no stop or no target, close it. |
| `EaCommand` | `Running` | `Running`, `Paused` (no new entries, protection stays), or `Flatten` (close this magic and do not re-enter). |
| `IncludeSwapInRisk` | `true` | Add the estimated adverse swap over `MaxHoldHours` to the loss used for volume. |
| `MaxHoldHours` | `48` | Hold window for that swap estimate. Also the age limit when `CloseAfterMaxHold` is on. |
| `CloseAfterMaxHold` | `false` | Close this symbol's positions older than `MaxHoldHours`. |
| `MaxSwapToRiskPercent` | `50` | Skip the entry when estimated swap is more than this percent of the cash risk. `0` disables the skip. |
| `ExitBeforeTripleSwap` | `false` | Close this symbol shortly before a triple-swap night. |
| `SwapChargeHour` | `21` | Broker-server hour of the swap charge. Used only by the optional triple-swap exit. Confirm it on the symbol. |
| `SwapChargeMinute` | `0` | Broker-server minute of that charge. |
| `ExitMinutesBeforeSwap` | `15` | How early the optional triple-swap exit starts. |
| `SizeForSlippage` | `true` | Size the trade from an entry `SlippageAllowancePoints` worse than the live quote. The order still uses the real swing stop and a 2R target from the live quote. |
| `SlippageAllowancePoints` | `20` | Those extra adverse points. `0` disables the allowance. |
| `MaxAdverseSlippagePoints` | `20` | Close the new fill when adverse slippage exceeds this many points. `0` disables. |
| `MaxAdverseSlippageStopPercent` | `25` | Close the new fill when adverse slippage exceeds this percent of the stop distance. `0` disables. |
| `TightenStopsNearDailyLimit` | `true` | While algorithmic trading is on, move stops closer once daily loss reaches `DailyLimitTightenPercent` of the limit. |
| `DailyLimitTightenPercent` | `75` | That threshold, as a percent of `DailyLossLimitPercent`. |
| `AlertOnAlgoOff` | `true` | Alert when Algo Trading is off. |
| `PushOnAlgoOff` | `true` | `SendNotification` when it turns off. Needs a MetaQuotes ID in the terminal. |
| `EmailOnAlgoOff` | `false` | `SendMail` when it turns off. Needs the terminal's email settings. |
| `WriteHeartbeat` | `true` | Update terminal global variables a watchdog can read. |
| `WriteHeartbeatFile` | `true` | Also write `MQL5/Files/PrimeMeta5_<login>.heartbeat.txt`. |
| `HeartbeatSeconds` | `10` | Minimum gap between heartbeat updates. |

The chart comment shows `RUNNING`, `PAUSED`, `LOCKED`, `FLATTEN`, or `ALGO_OFF`. There is no DLL. A server-side stop is still the protection that works after the Algo Trading button is turned off.

`OnInit` rejects a magic of 0, a negative deviation, out-of-range periods, a non-positive reward, a fast EMA that is not shorter than the slow EMA, a minimum ATR percent that sits above a positive maximum, a margin cap outside `(0, 100]`, and out-of-range values for the v1.40 and v1.41 caps. A symbol whose trade mode is disabled or close-only fails init. Long-only and short-only symbols are logged and the disallowed direction is skipped.

## Install

1. Install the MetaTrader 5 terminal PrimeXBT gives you, or the MetaQuotes terminal, and log in to the Standard account with the **trading** password.
2. In Market Watch, show all symbols. Confirm each allowlist name exists exactly. Open the specification and write down digits, point, tick size, volume min/step/max, stops level, freeze level, filling mode, swap, and trade mode. `SOLUSDT` and `BNBUSDT` are the strings in the source; PrimeXBT's May 2025 announcement wrote those pairs as `SOL/USDT` and `BNB/USDT`. If the Market Watch name differs, the EA stops with `INIT_FAILED`.
3. In the terminal: File → Open Data Folder. Copy `MQL5/Experts/PrimeMeta5/Crypto_4H_30M_Pullback_MT5.mq5` from this repo into the same path under that data folder.
4. Open the file in MetaEditor and press F7. Trade only after the compile reports 0 errors. The `.ex5` is gitignored.
5. Attach one instance to each symbol. The chart period can be M30. Enable algorithmic trading on **one** terminal only.
6. In the Experts log, confirm a line that the daily baseline was set, and confirm there is no "Symbol not in approved list" line.
7. Backtest and forward-test before any live order. The sequence and the hosting options are in [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).

H4 EMA 200 needs 201 H4 bars before the last closed bar can have a value. On a 24-hour market that is about 33.5 days of history. Until those bars exist, there is no trend signal.

## Repository layout

```
MQL5/Experts/PrimeMeta5/Crypto_4H_30M_Pullback_MT5.mq5   EA source, v1.40
docs/PRIMEXBT_STANDARD_README.txt                        owner's original note, unchanged
docs/AUDIT.md                                            v1.30 audit and the v1.40 resolution
docs/DEPLOYMENT.md                                       hosting options and rollout
CHANGELOG.md                                             1.40 changes by finding id
.github/workflows/compile-ea.yml                         MetaEditor compile on Windows
LICENSE                                                  placeholder, no licence chosen
```

## Build

Compile with MetaEditor on Windows (F7), on the same terminal build you will trade with. The GitHub Actions workflow [`.github/workflows/compile-ea.yml`](.github/workflows/compile-ea.yml) installs MetaTrader 5 on a Windows runner and uploads the `.ex5` as an artifact. On 3 November 2026 it compiled this source with 0 errors and 0 warnings ([run 41741433862](https://github.com/netdotx42/PrimeMeta5/actions/runs/41741433862)). Details and the two earlier failed attempts are in [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md). Prefer an `.ex5` built on the machine that will run it.

## Risk disclaimer

This software places orders on whatever account the terminal is logged into. Stops can fill worse than the price used to size the trade. Gaps, spread, swap, and any administrative fee sit outside the 0.5% figure. Correlated crypto positions can lose together. A chart that is closed, a terminal that is asleep, or a second copy of the account on another machine is outside the daily lock. Strategy Tester results depend on the tick model, the history the broker actually has, and the commission and swap you type in. They are not future results.

The author of the source said it had not been compiled or backtested in the environment where it was written. This repository does not add a backtest and does not claim one. You are responsible for the account, the contract specification, and the decision to turn algorithmic trading on.

PrimeXBT contract specifications, symbol names, and fees change. The public pages cited in the audit and the deployment plan were read on 3 November 2026. Re-read the specification inside the terminal before relying on them.
