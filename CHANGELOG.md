# Changelog

## 1.40

Entry rules are unchanged: H4 EMA 50/200 trend, M30 EMA 20 pullback, bullish or bearish close, break of the prior M30 candle, swing stop, 2R target.

| ID | What changed |
| --- | --- |
| H1 | The M30 bar is consumed only after the evaluation is finished. Indicator or quote failure, and a transient trade retcode, are retried until `MaxEntryDelaySeconds` (default 20). |
| H2 | One terminal-wide entry lock is held from the position check through the send. `MaxOpenPositions` (default 4) and `MaxTotalRiskPercent` (default 2) cap this magic across symbols. The defaults still allow four 0.5% positions; the lock stops them all passing on the same unread equity. |
| H3 | `CloseAllMagicOnDailyLock` (default true) closes every symbol with this magic from any live chart of this EA. The lock is still this terminal's global variables. Magic `0` is rejected so that close cannot take manual trades. |
| M1 | The daily baseline is published by one chart, under `GlobalVariableSetOnCondition`. A later chart reads the stored value. |
| M2 | `ExtraCostPerLot` (default 0) is added to the one-lot stop loss before sizing. The fill price and fill volume are logged. A negative `DeviationPoints` is rejected. Swap, and slippage inside the deviation, are still outside the formula. |
| M3 | `ExcludeNonTradeCashflows` (default true) removes balance, credit, bonus, and correction deals from the daily comparison. Floating PnL and swap still move the lock. |
| M4 | A baseline of 0 or less is deleted. Until a positive baseline exists, new entries stay off and nothing is closed because of the daily check. |
| M5 | `PLACED` is not treated as an open position. After `DONE` or `DONE_PARTIAL`, the position's stop and target are read. If either is missing and `VerifyStopsAfterFill` is true (default), the position is closed. The same check runs on later ticks for this symbol. |
| M6 | Init fails on a disabled or close-only symbol, logs trade mode, filling flags, hedging or netting, stops level, and freeze level, and skips a direction the symbol does not allow. One `INVALID_FILL` is retried with IOC, FOK, and RETURN. The allowlist is still an exact string match. |
| M7 | In the Strategy Tester the EA prints that a single pass does not exercise the cross-chart lock and that open-prices mode does not model stops. The tester still cannot run the four charts as one account. |
| M8 | A tick later than `MaxEntryDelaySeconds` does not enter; the skip is logged. A restart, or an init that cannot see M30 time, waits for a later bar instead of entering mid-bar. |
| M9 | If algorithmic trading is off, a protective close is not attempted in silence. The EA prints and alerts, at most once a minute, and tries again on a later tick. The terminal still refuses the close until trading is enabled. |

Low findings L1, L2, and L4–L7 are not part of this version. L3 is covered where H3 and M2 required it (magic 0 and a negative deviation).

## 1.30

Initial import of the owner's Expert Advisor. See `docs/PRIMEXBT_STANDARD_README.txt`.
