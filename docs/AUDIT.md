# Audit: Crypto_4H_30M_Pullback_MT5

Audit date: 3 November 2026, against v1.30. The line numbers in the narrative below are the v1.30 file (SHA-256 `54c0cda7a0a3c233c5e5c4e721f6572784dc044bf75840186a2ede1d72e9178f`). v1.40 applies the high and medium findings. The resolution is the table in the next section, and the code is the source of truth. The patch sketches further down were the v1.30 proposals; v1.40 follows them where they still matched the file, and differs where an input was the safer choice.

v1.30 was not attached to a PrimeXBT account. It compiled on 3 November 2026 with 0 errors and 0 warnings ([run 41741433862](https://github.com/netdotx42/PrimeMeta5/actions/runs/41741433862)). That log is not a backtest and not a live fill.

Severity used here:

| Level | Meaning |
| --- | --- |
| Critical | A current MT5 build should fail to compile the file, or normal operation can send an order with no bound and no stop. |
| High | A condition that actually happens on a live terminal (a short data gap, several charts, a second terminal, a restart) skips a signal, stacks entries, or leaves the daily loss control unable to do what its name says. |
| Medium | Size, stops, tester evidence, or a broker constraint can diverge from the inputs. Loss on the normal path is still bounded if the server accepts the stop. |
| Low | Cleanup, observability, and broker fields the current order path does not depend on. |
| Info | Confirmed behavior, including things that are by design. |

## Findings at a glance

| ID | Sev. | v1.40 | What |
| --- | --- | --- | --- |
| H1 | High | Fixed | `lastBarTime` was updated before `CheckSignal`, so one failed read or one rejected send skipped that M30 bar. |
| H2 | High | Fixed | Charts did not share an entry lock. Four symbols could each pass the 0.5% check before any fill, and two charts of one symbol could both send. |
| H3 | High | Partial | The daily closer only closed this magic on this chart's symbol, and the lock lives in this terminal's global variables. |
| M1 | Medium | Fixed | The daily baseline was check-then-set. `OnInit` published it immediately. A later chart could overwrite it. |
| M2 | Medium | Partial | Swap over a configured hold, and a slippage allowance, are inside the size by default. A bad fill can be closed. A swap credit, an unknown swap mode, and a gap through the stop are still outside the budget. |
| M3 | Medium | Partial | The baseline is account equity. Floating PnL and swap still move the lock. Deposits and withdrawals no longer do, by default. |
| M4 | Medium | Fixed | A baseline stored as 0 or less was kept for the whole server day and treated as a tripped limit, including the closer. |
| M5 | Medium | Fixed | A successful return code was logged as "opened" without reading the position's stop and target. `TRADE_RETCODE_PLACED` counted as success. |
| M6 | Medium | Partial | Only a disabled trade mode was rejected. Filling mode had no fallback. The allowlist is still an exact, case-sensitive match. |
| M7 | Medium | Partial | A one-symbol Strategy Tester run does not exercise the multi-chart lock. "Open prices only" is still the wrong model for stops. |
| M8 | Medium | Fixed | The first tick of a bar entered even if that tick was late. A restart skipped the forming bar with no log. |
| M9 | Medium | Partial | Server-side stops and a pre-limit tighten run while trading is allowed. The button still cannot be switched on by the EA. Alerts, push, email, a chart state, and a heartbeat cover the outage. |
| L1 | Low | Yesterday's `PXBTSTD_CRYPTO_*` global variables are never deleted. |
| L2 | Low | `SYMBOL_TRADE_FREEZE_LEVEL` is never read. New-order distance is governed by the stops level, which is checked. |
| L3 | Low | `DeviationPoints` and a magic of 0 are not rejected. A negative deviation converts into a large `ulong`. |
| L4 | Low | ATR, spread, trend, and "data not ready" return with no log line. A lock that already exists is silent. |
| L5 | Low | The day boundary and the optional end-of-day flatten use `TimeCurrent` (last tick). There is no timer. |
| L6 | Low | The volume step uses a `1e-9` bias inside `MathFloor`. |
| L7 | Low | If indicator handles are only partly created, `OnInit` returns `INIT_FAILED` without releasing the ones it has. |
| I1 | Info | `#property strict` is an MQL4 directive. It is not in the MQL5 property list. It was not shown to fail the build. |
| I2 | Info | The first valid H4 EMA 200 on the last closed bar needs 201 H4 bars, about 33.5 days on a 24-hour market. |
| I3 | Info | The news filter is off by default, fail-closed when on, and skipped entirely in the tester. |
| I4 | Info | Closed-bar H4 trend, 24/7 entries, and no modification of an existing position are what the source implements. |
| I5 | Info | The optional server check looks for the substrings `prime` and `pxbt`. It is off by default. |
| I6 | Info | The 30% margin cap is per order. Free margin is the check that sees orders already open. |
| I7 | Info | PrimeXBT public facts that touch this EA, and the questions those pages do not answer. |

## v1.40 resolution

The narrative under each finding describes v1.30. This is what v1.40 does with the high and medium items. Low and info items were left as written, except L3: magic `0` and a negative deviation are now rejected because H3 and M2 need that.

| ID | Status | How, and what remains |
| --- | --- | --- |
| H1 | Fixed | `OnTick` writes `lastBarTime` only after `CheckSignal` returns done. A short history read, a missing quote, and a transient retcode (`REQUOTE`, `PRICE_OFF`, `PRICE_CHANGED`, `TIMEOUT`, `CONNECTION`, `LOCKED`, `FROZEN`, `TOO_MANY_REQUESTS`, `CLIENT_DISABLES_AT`) leave the bar open. `IndicatorsReady` requires synchronized H4 and M30 series and enough calculated bars for EMA 200. |
| H2 | Fixed | `Acquire` on `PXBTSTD_CRYPTO_<login>_ENTRY` is held across the re-check and the send. Inside it, the EA re-reads positions, refuses a second position on the symbol, enforces `MaxOpenPositions` (default 4) and `MaxTotalRiskPercent` (default 2, so four 0.5% stops still fit), and refreshes the entry price before sizing. A stuck lock can be taken after 30 seconds. Lower the cap if four correlated positions are too much; the default does not do that for you. |
| H3 | Partial | `CloseAllMagicOnDailyLock` defaults to true, so any ticking chart closes every position with this magic. End-of-day close is still this symbol only. The baseline and the lock are still terminal global variables. A second terminal, a closed terminal, and a chart that never ticks do not flatten the book. Magic `0` is rejected so the wider close cannot grab manual trades. |
| M1 | Fixed | `EnsureDailyBaseline` takes a per-day guard with `GlobalVariableSetOnCondition` and only the holder writes. Everyone else reads. The guard value is a timestamp and can be stolen after 5 seconds. The baseline is not a temporary variable, so a restart the same server day keeps it. |
| M2 | Partial, narrowed in v1.41 | v1.40 added `ExtraCostPerLot` and logged the fill. v1.41, with the defaults on, also adds the estimated adverse swap over `MaxHoldHours` (48) and sizes from an entry `SlippageAllowancePoints` (20) worse than the quote. Weekday swap ratios come from the symbol; if they are all zero, the triple-swap weekday counts as three nights and the others as one. Money conversion uses `OrderCalcProfit`. A trade is skipped when that conversion fails, when the slippage allowance eats the stop, or when swap would be more than `MaxSwapToRiskPercent` (50) of the cash risk. A fill that slips more than 20 points or 25% of the stop distance is closed. Timed exits before triple swap and after the max hold are opt-in and default off. What remains: the swap figure is an estimate (reopen modes also pay the spread, and the charge clock can differ from 21:00 server time); a swap credit is not allowed to increase size; a gap through the stop can still lose more than the budget; `ExtraCostPerLot` is still 0 until you set a measured fee. |
| M3 | Partial | `ExcludeNonTradeCashflows` defaults to true. Balance, credit, bonus, and correction deals after the baseline timestamp are subtracted from equity before the percent is computed. Floating PnL and swap still count, so an open loss can still trip the lock and a large open profit can still set a high baseline. That is the protective reading of a daily equity limit. Set the input false to restore the v1.30 comparison. A baseline written by v1.30 has no timestamp; v1.40 stamps it at the first run and only adjusts cashflows after that. |
| M4 | Fixed | A stored baseline of 0 or less is deleted. `DAILY_NO_BASELINE` blocks new entries and does not call the closer. The closer runs only after a positive baseline has been breached, or when the lock key already exists. |
| M5 | Fixed | Success is `DONE` or `DONE_PARTIAL` only. `PLACED` is logged as not opened and does not send again on that bar. The position is then read. With `VerifyStopsAfterFill` (default true), a missing stop or target is closed, including on later ticks for this symbol. Turn the input off if a broker attaches stops after the deal comes back and the safety close is firing on good trades. |
| M6 | Partial | Init fails for `SYMBOL_TRADE_MODE_DISABLED` and `CLOSEONLY`, and prints trade mode, filling flags, account margin mode, stops level, and freeze level. A long-only or short-only symbol skips the disallowed direction. `INVALID_FILL` is tried once each as IOC, FOK, and RETURN. The allowlist is still exact and case-sensitive. `PositionSelect` still blocks when any position exists on the symbol. |
| M7 | Partial | `OnInit` in the tester prints that one pass is not a four-chart test and that open-prices mode does not model stops. The news filter is still bypassed there. Global variables in the tester are still per agent and still disappear with the pass. Nothing in the EA can make the single-symbol tester share a baseline across symbols. |
| M8 | Fixed | The same `MaxEntryDelaySeconds` window refuses a late tick and logs the skip. If `iTime` is 0 at init, the first bar that later appears is skipped. If init can see the open bar, that bar is skipped, as in v1.30, and the skip is now logged. |
| M9 | Partial, narrowed in v1.41 | v1.40 alerted and retried. v1.41 keeps a server-side stop on every accepted entry (`VerifyStopsAfterFill` still defaults on) and, while the button is on, tightens those stops once daily loss reaches 75% of the limit (`TightenStopsNearDailyLimit`). If a legal stop cannot fit the remaining budget, that position is closed. `EaCommand` adds Paused and Flatten without depending on the terminal button. The chart comment shows RUNNING, PAUSED, LOCKED, FLATTEN, or ALGO_OFF. A transition to ALGO_OFF sends an Alert and, by default, `SendNotification`. Email is off until `EmailOnAlgoOff` is turned on. The next tick after the button returns runs closes and stop updates that were waiting. Heartbeat global variables `PXBTSTD_CRYPTO_<login>_BEAT` and `_STATE` are updated, and `MQL5/Files/PrimeMeta5_<login>.heartbeat.txt` is written. No DLL is included: MQL5 cannot switch the button, a DLL is not allowed on MQL5 Virtual Hosting, and a keystroke tool can hit the wrong window. What remains: with the button off, a missing stop cannot be repaired and a position cannot be closed or tightened until the button is on, or until you close it from the Trade tab. Push and email do nothing until the terminal is configured. |

No critical finding in v1.30. On the path that sent an order, that version calculated a stop, rejected a stop inside `SYMBOL_TRADE_STOPS_LEVEL` of the live bid or ask, sized from that stop, and sent the stop and target on the same `CTrade` request. It did not read the position back. v1.40 does, when `VerifyStopsAfterFill` is on. The sections below are the v1.30 analysis.

## High

### H1. One M30 bar, one attempt, and the attempt is recorded first

`OnTick` reads the open M30 bar time, returns if it matches `lastBarTime`, then stores the new time and only then calls `CheckSignal` (lines 664–669):

```mql5
datetime barTime = iTime(_Symbol, PERIOD_M30, 0);
if(barTime == 0 || barTime == lastBarTime)
   return;

lastBarTime = barTime;
CheckSignal();
```

`CheckSignal` returns on almost every problem the same way it returns when there is no setup: `CopyBuffer` did not return one value (`ReadValue`, lines 115–125), the H4 EMAs are not ready (lines 413–417), `CopyRates` is short (line 423), `SymbolInfoTick` fails (lines 392–394 and 456–458), or `OrderSend` fails (lines 543–549). The next ticks of that M30 bar see `barTime == lastBarTime` and never try again.

`OnInit` also stores the current M30 open time (line 622) and does not wait for `BarsCalculated`. The platform's own rule is that an Expert Advisor is started after a delay of at most 5 seconds, on whatever history is available, including when the server is not connected ([Program Running](https://www.mql5.com/en/docs/runtime/running)). The first synchronization of an MQL5 virtual terminal uploads chart history in the background and tells programmers to handle data that is still arriving ([Virtual Hosting rules, section V](https://www.mql5.com/en/vps/rules)).

Why it matters: a pullback that closes through the prior high is a property of one M30 bar. If the H4 series is still syncing, `CopyBuffer` fails, or the server answers "off quotes" or "requote" on the first tick, that signal is gone for 30 minutes. The log usually stays empty, because those returns do not `Print` (L4). After a MetaQuotes virtual-host migration this is the first half hour of each symbol, which is exactly when people look to see whether the EA is alive.

Fix: split "not ready" from "evaluated". Leave `lastBarTime` unchanged while H4/M30 are not synchronized, `Bars` is below `TrendSlowEMA + 2`, `BarsCalculated` is short, or the retcode is transient (`REQUOTE`, `PRICE_OFF`, `PRICE_CHANGED`, `TIMEOUT`, `CONNECTION`, `TRADE_CONTEXT_BUSY`). Give up after a short, logged delay so a retry does not become a late chase of a breakout. Sketch H1 in the patches section.

### H2. The 0.5% check is per chart, and the charts run together

Each Expert Advisor has its own thread ([Program Running](https://www.mql5.com/en/docs/runtime/running)). `GlobalVariableSetOnCondition` exists because those threads share global variables and need an atomic update ([documentation](https://www.mql5.com/en/docs/globals/globalvariablesetoncondition)). This EA never takes that lock around a send.

`CheckSignal` reads equity, computes a volume for `RiskPercent` (default 0.5), checks margin, and calls `Buy` or `Sell` (lines 514–539). Nothing stops the ETH, SOL, and BNB charts from doing the same while the BTC request is still in flight. `HasOurPosition` (lines 99–112) and `PositionSelect` (line 388) are also outside any lock, so two charts of `BTCUSDT` can both observe an empty book and both send. `CTrade` is synchronous only for the EA that called it.

Why it matters: the owner's note already says four simultaneous entries can risk about 2% before slippage, gaps, and swap. The code makes that the normal case when four M30 bars close on the same timestamp, which they do. BTC, ETH, SOL, and BNB moving together means the four stops are one bet. The daily lock does not reserve that risk. It reacts after equity has already fallen (H3). A doubled BTC chart is worse, because it is the same symbol twice, and on a netting account the second fill increases the net position and, by platform rules, replaces the stop and target with the later order's prices ([position accounting](https://www.metatrader5.com/en/terminal/help/trading/general_concept)).

Fix: a terminal-wide mutex (`GlobalVariableTemp` to create a guard at 0 if it is absent, then `GlobalVariableSetOnCondition` from 0 to 1) held from the position check through `OrderSend`, released on every path. Inside the lock, re-read positions and equity. A portfolio cap (open stop-risk plus the new trade, measured with `OrderCalcProfit`, against the daily percent or a new input) is a behavior change and needs an explicit decision. Sketch H2.

### H3. "Daily loss 2%" does not flatten the account

`IsDailyLossLimitHit` (lines 232–258) compares account equity with a baseline stored under `DailyKey("BASE")` (lines 207–229). The key contains the account login and the date from `TimeCurrent`, which is the broker server time of the last tick. `CloseOurPositions` (lines 263–278) closes tickets whose symbol is `_Symbol` and whose magic is `MagicNumber`. Other symbols wait for their own charts to tick. A chart with no EA, a terminal that is closed, or a symbol that is not ticking is not closed. The owner's note says this. The code matches the note.

Global variables belong to one terminal. They are saved in that terminal's `gvariables.dat` and restored on its next start ([client terminal global variables](https://www.mql5.com/en/book/common/globals)). They are not an account-level switch on the broker. MQL5's hosting rules allow one trading account on several virtual terminals and warn that trading the same account from more than one place is unpredictable ([rules III.4 and VII.1](https://www.mql5.com/en/vps/rules)). The published migration list does not include terminal global variables ([rules, section V](https://www.mql5.com/en/vps/rules)). A second terminal, including a freshly migrated VPS, creates its own baseline from equity at the first call, so the morning's loss is not in the new baseline.

Why it matters: the control people rely on when they leave the EA unattended is local, reactive, and partial. A gap through four stops can realize more than 2% before any closer runs. A home terminal left logged in beside a VPS can open a second set of positions with a second baseline. Stopping the VPS for hoster maintenance (weekends up to 4 hours a day on the EET calendar, weekdays up to 15 minutes; [rules II.3](https://www.mql5.com/en/vps/rules)) freezes the closer for that window.

Fix: treat "one terminal, algorithmic trading on, every traded symbol has a live chart" as a deployment rule (see the deployment plan). In code, the closer can loop every symbol this magic owns, not only `_Symbol`, so one live chart can flatten the set when the lock trips. That still does nothing for a terminal that is not running. There is no MQL5 API in this EA that can close positions on a machine that is off.

## Medium

### M1. The baseline publish is not atomic

Lines 217–229:

```mql5
double GetDailyBaseline()
{
   string key = DailyKey("BASE");
   if(!GlobalVariableCheck(key))
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      GlobalVariableSet(key, equity);
      Print("Daily equity baseline set to ", equity);
      return equity;
   }
   return GlobalVariableGet(key);
}
```

`GlobalVariableCheck` plus `GlobalVariableSet` is two steps. Another EA's thread can pass the check before the first `Set`. Both write. The last write becomes the baseline for every later read. The writer returns its own equity, so for one call the two charts can disagree. `GlobalVariableSetOnCondition` will not create a missing variable; it returns false and sets error 4501 ([documentation](https://www.mql5.com/en/docs/globals/globalvariablesetoncondition)). `GlobalVariableTemp` creates a missing variable at 0 and does not turn an existing variable into a temporary one ([documentation](https://www.mql5.com/en/docs/globals/globalvariabletemp)). The baseline itself must stay persistent. A temporary baseline would forget the day's drawdown on every terminal restart and hand out a fresh 2%.

`OnInit` calls `GetDailyBaseline` unconditionally (line 625), including when `DailyLossLimitPercent` is 0. That call is the usual race window: four charts initialize together when the terminal connects. The platform may start the EA with incomplete history after at most 5 seconds ([Program Running](https://www.mql5.com/en/docs/runtime/running)). Equity is account state rather than chart history, so the usual error is a tick of floating PnL between the two writes, or a fill that lands in the same window. It is not a theoretical interleaving on a single thread. The threads are real.

Why it matters: the later writer resets the yardstick. A baseline moved down after a loss allows more than the configured 2% from the first chart's equity. A baseline moved up after a profit makes a normal give-back look like a daily loss and starts the closer.

Fix: create a persistent key only under a short-lived guard, and only if the stored value is still the empty sentinel. Sketch M1. Do not store the baseline with `GlobalVariableTemp`.

### M2. Position size ignores swap, fees, and the fill you actually get

`CalculateVolume` (lines 130–171) calls `OrderCalcProfit` for 1.0 lot from the decision price to the stop, takes the absolute value, and divides the cash risk by that number. The documented formulas are price difference times contract size (CFD modes) or the futures tick-value form. Commission and swap are not terms in those formulas ([OrderCalcProfit](https://www.mql5.com/en/docs/trading/ordercalcprofit), formula table in the [MQL5 book](https://www.mql5.com/en/book/automation/experts/experts_ordercalcprofit)). The volume is then floored to the step so the price-distance estimate stays inside the budget. That part is deliberate and correct for a linear CFD.

The send uses price `0.0`, which is a market order, with `DeviationPoints` defaulting to 20 (lines 536–539 and line 618). The profit estimate used the ask (buy) or bid (sell) from a few lines earlier. A fill anywhere inside the deviation is a larger loss than `RiskPercent`, and the stop price is not moved. `DeviationPoints` is not checked in `OnInit` (lines 586–603). See L3.

PrimeXBT, as published, changes how large the missing commission is:

- From 3 September 2025, PrimeXBT said crypto CFDs on MT5 Standard moved to a spread-only model and that commission charges were removed. Pro accounts were excluded. The MT5 Standard table on that post names the instruments `BTCUSDT`, `ETHBTC`, and `ETHUSDT` ([blog, 5 September 2025](https://primexbt.com/company-blog/crypto-cfds-on-pxtrader-and-mt5-are-now-spread-only/)).
- The Help Centre FAQ says MT5 has no trading fees, and that swap fees may be replaced with administrative fees depending on the account type ([FAQ](https://primexbt.help/en/articles/8461245-frequently-asked-questions-f-a-q-platform-wide)).
- The trading-conditions article (6 August 2026) says standard MT5 commissions are replaced with administrative fees, that swaps apply to overnight positions unless the account is swap-free, that fee tiers do not apply to MT5, and that the exact swap is on the platform ([article](https://primexbt.help/en/articles/16240701-trading-conditions-explained)).
- A 2024 operations post set the overnight swap timestamp to 21:00 UTC in European summer time and 22:00 UTC in European winter time, for PrimeXBT and for MT5 ([blog](https://primexbt.com/company-blog/important-information-regarding-swaps-on-primexbt-and-mt5/)).

The spread on entry is inside the estimate, because a buy is sized from the ask and a sell from the bid. What the estimate does not contain is a worse stop fill, swap or an administrative fee while the position is open, and any charge the FAQ still calls an administrative fee. This EA has no time stop. A position can be held across multiple swap postings. Those amounts were not published as numbers. Read them in the symbol specification. The two help articles and the 2025 blog do not use the same words for "administrative fee", so this audit does not collapse them into "cost is zero".

Why it matters: on a Standard account the published commission gap is small or zero, and the remaining leak is swap, fees, and slippage. On a Pro account the 2025 post said commissions were unchanged, and this sizing model would overstate the risk budget. `RequirePrimeXBTServerName` does not distinguish Standard from Pro.

Fix: keep `OrderCalcProfit` for the price loss. Add a per-lot cost input, taken from a closed deal on that account (`DEAL_COMMISSION`, `DEAL_FEE`, `DEAL_SWAP`), and subtract it inside the volume division. Log `ResultPrice()` next to the requested price. Reject a negative `DeviationPoints` at init.

### M3. The lock follows equity, not today's closed trades

The drawdown is `(baseline - equity) / baseline` (lines 246–254). Equity includes open profit, open loss, swap already posted, deposits, and withdrawals. The baseline is whatever equity was when the key was created, which the owner's note correctly says is the first start of the day, not necessarily midnight.

Why it matters: a withdrawal, a negative swap posting, or another EA's open loss can cross 2% and flatten this EA's positions. A position carried overnight with a large open profit sets a high baseline the next morning; giving that profit back looks like a new daily loss. The reverse, a baseline taken while a carried position is underwater, allows a deeper loss from the start-of-day balance. None of this is visible as a separate log line.

Fix: document it in the runbook, which the deployment plan does. A code change would snapshot balance, or ignore deals of type `DEAL_TYPE_BALANCE`, and would be a behavior change. Do not "fix" it silently.

### M4. A non-positive baseline sticks for the server day

If the stored baseline is `<= 0`, `IsDailyLossLimitHit` returns true immediately (lines 240–241). It does not write the lock key, and it does not try again. `OnTick` then calls `CloseOurPositions` and returns (lines 651–655). The bad baseline remains until the date in the key changes.

The only writer is `GetDailyBaseline`, and it stores `AccountInfoDouble(ACCOUNT_EQUITY)` whenever the key is absent, including the call from `OnInit` (line 625). A first read of 0, from a not-yet-connected account or an empty one, becomes a day-long halt and a close attempt. There is a log line, "Daily equity baseline set to 0", which is the way to see it. This audit did not capture a live login, so it does not claim the first read is 0 on a normal PrimeXBT connect. The sticky interpretation of that value is in the source.

Fix: if equity is not strictly positive, or `TERMINAL_CONNECTED` is false, do not create the key. If a stored value is not strictly positive, delete it and wait. Treat "no baseline yet" as "do not trade", and do not treat it as "close everything" unless a real positive baseline has been broken.

### M5. The order result is not checked against the position

Lines 543–558 treat `TRADE_RETCODE_DONE`, `TRADE_RETCODE_DONE_PARTIAL`, and `TRADE_RETCODE_PLACED` as success and print "BUY opened" or "SELL opened" with the requested price, not `ResultPrice()`. A partial fill is not followed by a second send. `PLACED` is the usual result for a pending order, not for a market order; counting it as an open position means the next bar can send again if no position appeared. The position's `POSITION_SL` and `POSITION_TP` are never read. If the server accepts the deal and does not keep the stops, the only later exit in the default configuration is the daily closer or a manual close.

PrimeXBT describes these instruments as crypto CFDs. This audit did not find a public statement of the MT5 execution mode (`SYMBOL_TRADE_EXEMODE`) or of whether stops are stored on the position. Confirm both on a demo fill before live use.

Fix: after a `DONE` or `DONE_PARTIAL` result, select the position and require a non-zero stop on the correct side. If it is missing, close immediately and log that the close is a safety close. Log `ResultPrice()` and `ResultVolume()`. Treat `PLACED` on this market path as not-yet-open.

### M6. Broker constraints the init check does not cover

`OnInit` returns `INIT_FAILED` when `SYMBOL_TRADE_MODE` is `SYMBOL_TRADE_MODE_DISABLED` (lines 581–585). It does not reject `CLOSEONLY`, `LONGONLY`, or `SHORTONLY`. A sell signal on a long-only symbol fails at the server, and H1 then skips the rest of the bar.

`trade.SetTypeFillingBySymbol(_Symbol)` (line 619) is the standard-library helper. Published copies of `Trade.mqh` prefer `ORDER_FILLING_FOK` when the symbol advertises FOK, then IOC, then RETURN. This audit did not open the copy that ships with a current terminal, so confirm that order in your `Include/Trade/Trade.mqh`. There is no second try in this EA on `TRADE_RETCODE_INVALID_FILL`. PrimeXBT's filling flags were not in the public pages. Log `SYMBOL_FILLING_MODE` at init and, on a demo, confirm one market order is accepted.

`IsAllowedSymbol` (lines 64–74) compares `_Symbol` to the allowlist after trimming whitespace. The comparison is case-sensitive and does not strip a broker suffix. PrimeXBT's September 2025 Standard table uses `BTCUSDT` and `ETHUSDT` as instrument codes. The May 2025 list of the first MT5 crypto CFDs writes the pairs with a slash, including `BTC/USDT`, `ETH/USDT`, `SOL/USDT`, and `BNB/USDT` ([blog](https://primexbt.com/company-blog/crypto-cfds-now-available-on-mt5-with-expanded-instrument-selection/)). Those two public styles are not the same string. A mismatch is safe (the EA does not trade) and easy to misread as "the EA is broken". `BASE` is not on the list, which matches the owner's note that no BASE instrument was confirmed.

`PositionSelect(_Symbol)` (line 388) is commented as a netting guard. On a hedging account the same call returns true when any position on the symbol exists, and the EA then skips the entry. PrimeXBT's hedge-mode announcement is about the crypto futures platform, not MT5. The MT5 help page explains that hedging versus netting is a property of the account, set by the broker ([position accounting](https://www.metatrader5.com/en/terminal/help/trading/general_concept)). Which one PrimeXBT Standard uses was not in the pages read. Read `ACCOUNT_MARGIN_MODE` in the terminal.

Fix: at init, print trade mode, filling mode, margin mode, stops level, freeze level, and the exact `_Symbol`. Fail init on `CLOSEONLY`. Fail a buy on `SHORTONLY` and a sell on `LONGONLY` before the send, and log it once. Keep the allowlist exact; fix names in the input, not by guessing suffixes.

### M7. The Strategy Tester will not show you the risk control

During a test, terminal global variables are emulated inside the testing agent. They are not the F3 list of the terminal you are watching, each agent has its own copy, and they disappear when the pass ends ([Testing Trading Strategies](https://www.mql5.com/en/docs/runtime/testing)). A single-symbol test never runs the other three charts. A green BTC backtest says nothing about the 2% lock, the baseline race, or four correlated entries.

`IsNewsWindow` returns false when `MQL_TESTER` is set (lines 304–307), so a test with the filter turned on does not behave like live. Calendar functions are not available in the tester; calling them is reported as error 4014 by users and by the MQL5 book chapter on the calendar ([forum report](https://www.mql5.com/en/forum/312462), [book](https://www.mql5.com/en/book/advanced/calendar/calendar_cache_tester)). The bypass matches that limitation. With the default `EnableNewsFilter=false` it does not change results.

Tick model, from the same testing chapter:

- "Open prices only" is appropriate for systems that decide at the open of a bar and do not use stop loss or take profit. This EA does both. Stops will not be simulated in a way you can trust in that mode.
- "Every tick" generates ticks from minute bars. "Every tick based on real ticks" uses the broker's recorded ticks, and where a minute has no ticks the tester substitutes generated ticks.
- Spread in the tester is taken from historical bars, and the tester always reports the spread as floating. It is not a live PrimeXBT quote stream unless the real-tick history carries that spread.
- History is whatever the terminal has downloaded from the trade server you are logged into. This audit did not find a PrimeXBT promise of multi-year tick history.

Commission and swap in the tester are the values in the tester settings, not the values inside `OrderCalcProfit`. Leaving commission at the tester default while the live account charges a fee (or the reverse) produces a result this EA will not repeat.

The first 201 H4 bars cannot produce a slow-EMA value (I2). A test that starts on the first day of history looks like an EA that never trades, and then trades with an EMA that has only just been seeded.

Fix: test each allowlist symbol separately on real ticks, with the date starting well after H4 history exists, and with swap and any fee copied from that symbol's specification. Use the tester as evidence of entries, stops, and target distance. Use a demo forward test, with four charts in one terminal, as the evidence for the daily lock.

### M8. A quiet open and a restart do different things

If the terminal stays loaded, `lastBarTime` still holds the previous bar. The first tick of the new bar, whenever it arrives, updates `lastBarTime` and calls `CheckSignal`. There is no maximum age. A tick 20 minutes into the bar still sends, at a price that may have left the breakout, with a stop computed from that later quote (lines 482–503). Risk percent is preserved only relative to the new, possibly much smaller or larger, stop distance.

If the terminal restarts, `OnInit` sets `lastBarTime` to the forming bar (line 622). The signal of the bar that just closed is never evaluated. Reconnect-without-deinit and restart-with-deinit are opposite behaviors for the same outage.

Why it matters: a VPS reboot, a Windows update, or an MT5 update reloads the EA and skips the current bar. A frozen quote followed by one tick does the other thing and chases. Combined with H1, the operator cannot predict which of "missed" or "late" they will get.

Fix: the same short entry window as H1. If `TimeCurrent() - barTime` is already past that window when the EA wakes, log "skipped late bar" and store `lastBarTime` without sending.

### M9. Algorithmic trading off freezes the book; it does not flatten it

`CheckSignal` returns when `TERMINAL_TRADE_ALLOWED` or `MQL_TRADE_ALLOWED` is false (lines 380–382). `OnTick`'s daily-loss and end-of-day paths call `CloseOurPositions` without that check (lines 651–661). `PositionClose` is still a trade request. While algorithmic trading is disabled the platform rejects it, the EA logs the retcode, and the position stays. The same is true of the "disable algorithmic trading when the account / profile / chart changes" options in Tools → Options → Expert Advisors. A VPS that comes back with the button off looks safe and is not flat.

Why it matters: the button is the usual emergency control. For this EA it stops new risk and also stops the only automatic exit besides the broker-side stop and target.

Fix: in the runbook, an emergency flatten is "close the positions in the Trade tab", not "click Algo Trading off". In code, a failed protective close should `Alert`, not only `Print`, and should keep trying. It cannot succeed until trading is allowed again.

## Low

### L1. Old daily keys are never removed

Every server day adds `PXBTSTD_CRYPTO_<login>_YYYYMMDD_BASE` and, if the limit trips, `_LOCK`. Nothing calls `GlobalVariableDel`. Names are at most about 50 characters for a 64-bit login, under the 63-character limit documented for terminal global variables ([book](https://www.mql5.com/en/book/common/globals)). They persist in `gvariables.dat` across restarts. Two keys a day will not fill a terminal quickly. They do clutter F3, and a stale key is easy to misread during an incident.

Fix: on init, delete keys with this prefix whose date stamp is not today. Sketch L1. Do not delete the current day's `BASE` or `LOCK`.

### L2. Freeze level is unread; stops level is checked

`ValidStops` (lines 174–202) reads `SYMBOL_TRADE_STOPS_LEVEL` and measures a buy stop and target from the live bid, and a sell stop and target from the live ask. That matches the check MetaQuotes requires before publication for a new market order ([article](https://www.mql5.com/en/articles/2555)). `SYMBOL_TRADE_FREEZE_LEVEL` does not appear in the file.

The freeze level is the distance inside which an existing pending order, or an existing position's stop and target, cannot be modified ([symbol properties](https://www.mql5.com/en/docs/constants/environment_state/marketinfoconstants), [same article, modification section](https://www.mql5.com/en/articles/2555)). This EA never sends a modification. The hypothesis "freeze level is not checked" is true. The hypothesis "new entries ignore a broker distance they are required to respect" does not hold for the published stops-level rule, because that rule is implemented, including the bid/ask side.

Residual risk: some bridges treat freeze level as an extra distance on new stops, and a later trailing-stop change would need the check. `PositionClose` of a position whose stop is already inside the freeze distance is the case the modification rules are about; this EA's closer does not look at it. If a demo close fails only when price is on top of the stop, add `max(stopsLevel, freezeLevel)` to `minDistance`.

### L3. Two inputs skip the init validator

The validator (lines 586–603) covers risk, reward, EMA order, swing length, spread, daily loss, news minutes, the end-of-day clock, ATR, and the margin cap. It does not look at `DeviationPoints` (line 21, `int`) or `MagicNumber` (line 20, `ulong`). `SetDeviationInPoints` takes an unsigned value. A negative deviation converts to a very large allowance, so the "maximum slippage" becomes the opposite. Magic `0` is also the magic of a manual trade. `HasOurPosition` and `CloseOurPositions` would then treat manual positions on that symbol as theirs, and a daily lock would close them.

Fix: require `DeviationPoints >= 0` and `MagicNumber != 0`.

### L4. The interesting returns are silent

These paths `Print`: minimum lot above the risk budget (line 166), `OrderCalcProfit` failure (line 141), invalid stops (line 510), margin cap (line 526), order failure (line 548), init failure, baseline creation (line 225), and the moment the lock is set (lines 252–253).

These paths do not: ATR out of band, spread filters, no trend, no pullback, `CopyBuffer` / `CopyRates` / `SymbolInfoTick` failure, trade not allowed, and an already-existing position. After the lock key exists, later ticks return true at lines 244–245 with no new line. A restart on a locked day looks like an EA that simply never trades.

Fix: once per consumed bar, print a single reason code. When the lock is already set, print once per init, not once per tick.

### L5. The clock is the last tick

`DailyKey` and `IsEndOfDay` use `TimeCurrent` (lines 210 and 288). `IsNewsWindow` uses `TimeTradeServer` (line 309). There is no `OnTimer`. `TimeCurrent` does not advance while no tick arrives. On a dead symbol the server date does not roll inside the EA, and the optional end-of-day flatten does not run, until the next quote. Crypto CFDs usually tick. A halted symbol or a disconnected terminal does not.

The default of `EnableEndOfDayClose` is false, so the 23:45 cutoff is dormant. If it is turned on, the flatten and the entry block run from that minute until midnight, server time, and a new entry can still be considered on the first tick of the next day based on the bar that closed at midnight.

`TimeTradeServer` is the terminal's estimate of server time from the local clock. A VPS with a bad clock affects the news filter. It does not affect the daily key, which follows ticks. Keep NTP on anyway.

### L6. Step rounding is slightly biased upward

Line 158 adds `1e-9` before `MathFloor` so a value that is mathematically on a step, and one ulp under it in floating point, is not floored to the previous step. A value that is truly just below a step can be nudged up by that bias and then normalized. The excess risk is a fraction of one volume step. Worth knowing if you later tighten the budget to the last cent. Not worth changing ahead of H1–H3.

### L7. Partial indicator failure skips `IndicatorRelease`

Handles are created at lines 605–608. If any of them is `INVALID_HANDLE`, init returns at lines 610–614 without releasing the handles that succeeded. `OnDeinit` (lines 635–644) does release them. Whether the terminal calls `OnDeinit` after a failed `OnInit` has varied by build; this audit does not depend on it. The EA is not left running. On the next successful init, new handles are created. Low.

## Info

### I1. `#property strict` is an MQL4 directive

Line 1. The MQL5 property table lists `version`, `description`, `copyright`, indicator properties, tester properties, and so on. `strict` is not among them ([Program Properties](https://www.mql5.com/en/docs/basis/preprosessor/compilation)). In MQL4 it selected the strict compiler mode. MQL5 is already strict about types and array bounds. A long-standing MQL5 forum reply says the directive is ignored in MQL5 ([forum](https://www.mql5.com/en/forum/425625)).

The compile workflow's green run on 3 November 2026 is a real compiler log, not that forum reply. MetaEditor from that day's `mt5setup.exe` reported `Result: 0 errors, 0 warnings, 1114 ms elapsed, cpu='X64 Regular'`. There was no "unknown property" line for `strict`. The process exit code was 1, which on that build meant one file compiled, not one error. Removing the line is still a harmless source edit and is not done here. It does not change signals. Run: [41741433862](https://github.com/netdotx42/PrimeMeta5/actions/runs/41741433862).

### I2. EMA 200 on H4 needs about five weeks of bars, not a magic 35

`iMA` on H4 with period 200 is created at line 606. `CheckSignal` reads shift 1, the last closed bar (lines 413–417). `ReadValue` rejects a failed copy and rejects `EMPTY_VALUE` (lines 115–125). A moving-average buffer has no usable value until a full period of prices exists; earlier elements are the empty value.

For shift 1 to be that first usable bar, the series needs the forming bar plus 200 closed bars: **201 H4 bars**. At four hours each, that is 804 hours, which is **33.5 days** of a market that prints an H4 bar every four hours. "About 35 days" is the right operational estimate and the wrong exact constant. Weekends or halts, if this contract has any, add calendar time. The first non-empty EMA is seeded from the first window of prices, so the following weeks are still influenced by that seed. Waiting longer is a judgment about indicator convergence, not a second gate the terminal enforces.

Until the copy succeeds, H1 turns every M30 bar in the warm-up into a silent skip. After it succeeds, the next new bar can trade. A Strategy Tester range that starts on day one of the file has the same warm-up built in.

### I3. News filter

Default off (line 46). When on, high-importance events for the configured currencies block entries from `NewsMinutesBefore` minutes before the event until `NewsMinutesAfter` minutes after it (`from = now - NewsMinutesAfter`, `to = now + NewsMinutesBefore`, lines 309–311). A calendar error, an unreadable event, or an empty currency list blocks entries (lines 316–366). That is fail-closed, and it will also stop the EA for as long as the calendar service is down. The tester bypass is I7's neighbor, described under M7. The filter does not close an open position.

### I4. What the signal code actually implements

These were checked against the source and kept as behavior, not defects:

- H4 EMAs and the M30 EMA are read at shift 1. The forming bar is not an input to the signal. Trend can be up to four hours old. That is the closed-bar design.
- Buy and sell cannot both be true: one requires the close above the M30 EMA, the other requires it below.
- The swing copy asks for `SwingLookback + 2` closed M30 bars and the loop touches indices `0` through `SwingLookback - 1` only (lines 419–471). With `SwingLookback >= 2` enforced at init, that is in range. The stop includes the signal candle's extreme.
- A volume below `SYMBOL_VOLUME_MIN` is refused, not rounded up (lines 163–168).
- `SetAsyncMode(false)` is set (line 620), so a retcode read immediately after `Buy` / `Sell` belongs to that call.
- No trailing stop, break-even, or partial close. The owner's note says existing positions are not modified. The source does not modify them.
- Entries are allowed 24 hours if the other filters pass. `EnableEndOfDayClose` defaults to false.

### I5. Server-name check

Lines 569–579. Default false, which matches the owner's note that server strings vary. When enabled, it lowercases `ACCOUNT_SERVER` and `ACCOUNT_COMPANY` and looks for `prime` or `pxbt`. Any other broker whose company string contains those letters would pass. A PrimeXBT legal entity that contains neither would fail closed. The real server string was not published on the pages read for this audit. Read it in the terminal before turning the input on.

### I6. Margin cap

Lines 518–528. `OrderCalcMargin` is called for the new volume at the decision price. The order is skipped when that margin is above `MaxMarginEquityPercent` of equity (default 30) or above `ACCOUNT_MARGIN_FREE`. The 30% test does not add up margin already in use. The free-margin test does. Four tight-stop trades can still be attempted; the later ones should fail the free-margin test if the earlier fills have landed. H2 is the case where they have not landed yet.

### I7. PrimeXBT facts used in this audit

Read on 3 November 2026. Re-check in the terminal. Public pages and the live specification do diverge.

| Topic | What the public page says | Source |
| --- | --- | --- |
| Instrument codes on MT5 Standard | The September 2025 spread table lists `BTCUSDT`, `ETHUSDT`, `ETHBTC`. | [Spread-only post](https://primexbt.com/company-blog/crypto-cfds-on-pxtrader-and-mt5-are-now-spread-only/) |
| First crypto CFD names | May 2025 list uses a slash: `BTC/USDT`, `ETH/USDT`, `SOL/USDT`, `BNB/USDT`, and others. `BASE` is not in that list. | [Launch post](https://primexbt.com/company-blog/crypto-cfds-now-available-on-mt5-with-expanded-instrument-selection/) |
| Commission | Standard crypto CFDs described as spread-only from 3 September 2025. Pro excluded. Later help text says MT5 has no trading fees, and also says administrative fees replace standard commissions. | Blog above; [FAQ](https://primexbt.help/en/articles/8461245-frequently-asked-questions-f-a-q-platform-wide); [conditions](https://primexbt.help/en/articles/16240701-trading-conditions-explained) |
| Swap | Overnight swaps apply on MT5 unless the account is swap-free. 2024 post: charge time 21:00 UTC (EU summer) or 22:00 UTC (EU winter). | Conditions article; [swap-time post](https://primexbt.com/company-blog/important-information-regarding-swaps-on-primexbt-and-mt5/) |
| Fee tiers | Do not apply to MT5. | Conditions article |
| Demo | FAQ: a free demo exists and can be used on MT5 and on PXTrader 2.0. The articles do not say the demo's symbol strings, swaps, and filling mode equal a live Standard account. | [FAQ](https://primexbt.help/en/articles/8461245-frequently-asked-questions-f-a-q-platform-wide) |
| 2FA | Recommended on the website account. The pages do not say whether the MT5 trade-server login asks for a one-time password on every connect. | FAQ |

Not found in those pages, so not stated as fact: the MT5 server name, hedging versus netting, `SYMBOL_TRADE_STOPS_LEVEL`, `SYMBOL_TRADE_FREEZE_LEVEL`, contract size, volume step, digits, execution mode, and whether a demo login is the same specification as live Standard. The leverage and minimum deposit figures on marketing pages were not used.

## Hypotheses from the first read

| Hypothesis | Verdict |
| --- | --- |
| `#property strict` is an MQL4 directive. | Confirmed. It is not an MQL5 property. The 3 November 2026 MetaEditor run compiled the file with 0 errors and 0 warnings, so that build did not reject it. I1. |
| `lastBarTime` is updated before `CheckSignal`, so a transient failure skips the M30 bar. | Confirmed. Includes data-not-ready and a rejected send. H1. |
| The daily baseline is check-then-set, with no atomic publish, and old keys are never deleted. | Confirmed. The race is real because each EA has its own thread. M1, L1. The more serious hole is the missing entry mutex, H2, and the per-terminal closer, H3. |
| `SYMBOL_TRADE_FREEZE_LEVEL` is not checked. | Confirmed as a fact about the source. The entry-distance rule that applies to a new market order is the stops level, and `ValidStops` implements it against the live bid or ask. L2. |
| Position sizing ignores commission and swap. | Confirmed for `OrderCalcProfit`. On published PrimeXBT Standard crypto terms, commission is not the main gap; swap and any administrative fee still are, plus slippage inside `DeviationPoints`. M2. |
| EMA 200 on H4 needs about 35 days of H4 history before the first valid signal. | Approximately confirmed. The terminal's hard minimum for a value at shift 1 is 201 H4 bars, 33.5 days of continuous four-hour bars. I2. |

## Checked, and not filed as defects

- Swing-loop bounds and the series flag on `CopyRates`. The copied window is large enough for the indices the loop uses.
- A bar qualifying as both a long and a short. The close cannot be both above and below the M30 EMA.
- Forcing the minimum lot. The source refuses it.
- Ignoring `SYMBOL_TRADE_STOPS_LEVEL`. It is checked, on the close-price side of the position.
- Reading a stale `CTrade` retcode. Asynchronous mode is off.
- The include `Trade/Trade.mqh` and the calls `OrderCalcProfit`, `OrderCalcMargin`, `CalendarValueHistory`, `PositionGetTicket`, and `SetTypeFillingBySymbol`. The 3 November 2026 MetaEditor log included `Trade.mqh` and finished with 0 errors and 0 warnings ([run 41741433862](https://github.com/netdotx42/PrimeMeta5/actions/runs/41741433862)).

## Recommended patches

Not applied. Each one changes behavior. Approve them in a later change, and compile that change on the terminal you trade with.

### H1 and M8. Decide the bar only after the data is there

```mql5
input int MaxEntryDelaySeconds = 20;

bool IndicatorsReady()
{
   if(!SeriesInfoInteger(_Symbol, PERIOD_H4, SERIES_SYNCHRONIZED))
      return false;
   if(!SeriesInfoInteger(_Symbol, PERIOD_M30, SERIES_SYNCHRONIZED))
      return false;
   if(Bars(_Symbol, PERIOD_H4) < TrendSlowEMA + 2)
      return false;
   if(BarsCalculated(hSlow) < TrendSlowEMA + 2)
      return false;
   if(BarsCalculated(hFast) < TrendFastEMA + 2)
      return false;
   if(BarsCalculated(hEntry) < EntryEMA + 2)
      return false;
   if(BarsCalculated(hATR) < ATRPeriod + 2)
      return false;
   return true;
}

bool Transient(uint code)
{
   return code == TRADE_RETCODE_REQUOTE
       || code == TRADE_RETCODE_PRICE_OFF
       || code == TRADE_RETCODE_PRICE_CHANGED
       || code == TRADE_RETCODE_TIMEOUT
       || code == TRADE_RETCODE_CONNECTION
       || code == TRADE_RETCODE_TRADE_CONTEXT_BUSY
       || code == TRADE_RETCODE_TOO_MANY_REQUESTS;
}

void OnTick()
{
   if(IsDailyLossLimitHit()) { CloseOurPositions(); return; }
   if(IsEndOfDay())          { CloseOurPositions(); return; }

   datetime barTime = iTime(_Symbol, PERIOD_M30, 0);
   if(barTime == 0 || barTime == lastBarTime)
      return;

   if(TimeCurrent() - barTime > MaxEntryDelaySeconds)
   {
      Print("Skipping M30 bar ", TimeToString(barTime), ": first look is late.");
      lastBarTime = barTime;
      return;
   }
   if(!IndicatorsReady())
      return;                 // retry this bar; do not touch lastBarTime

   uint code = 0;
   if(!TryEntry(code))
   {
      if(Transient(code))
         return;              // retry until the window expires
   }
   lastBarTime = barTime;
}
```

`TryEntry` is today's `CheckSignal`, changed to return the retcode. Log the skip reason whenever it consumes the bar. Keep `lastBarTime = iTime(...)` in `OnInit` only when `iTime` is non-zero, so a restart still waits for the next bar, and a zero `iTime` does not arm a mid-bar entry.

### H2. One sender at a time

```mql5
bool Acquire(const string guard, int timeoutMs)
{
   GlobalVariableTemp(guard);             // creates 0 if absent; does not reset a live guard
   uint start = GetTickCount();
   while(GetTickCount() - start < (uint)timeoutMs)
   {
      if(GlobalVariableSetOnCondition(guard, 1.0, 0.0))
         return true;
      Sleep(20);
   }
   return false;                           // fail closed: skip the entry
}

void Release(const string guard)
{
   GlobalVariableSet(guard, 0.0);
}
```

Hold the guard from the `HasOurPosition` / `PositionSelect` re-check through `Buy`/`Sell`, and `Release` on every return, including the volume and margin failures. A crash while the guard is 1 blocks new entries until the terminal restarts (`GlobalVariableTemp` drops it on shutdown). That is the safer failure. A portfolio cap on top of this is optional and changes which signals are taken; write it down as its own input if you want it.

### M1 and M4. Publish the baseline once

Use a guard of the same shape, then:

```mql5
if(!TerminalInfoInteger(TERMINAL_CONNECTED))
   return 0.0;
double equity = AccountInfoDouble(ACCOUNT_EQUITY);
if(equity <= 0.0)
   return 0.0;
if(!GlobalVariableCheck(key) || GlobalVariableGet(key) <= 0.0)
   GlobalVariableSet(key, equity);
return GlobalVariableGet(key);
```

Call that only from the EA that won the guard. Everyone else waits until the key is a positive number. If there is no positive baseline, do not open and do not close. Closing is reserved for a baseline that was positive and has since been breached. Keep the key persistent so a restart mid-day does not reset the yardstick.

### H3. Close every symbol this magic owns

Walk `PositionsTotal` and close every ticket with `POSITION_MAGIC == MagicNumber`, not only `_Symbol`. One live chart can then flatten the other three after the lock trips. It still cannot flatten a terminal that is not running.

### M2 and M5. Cost and proof of stops

```mql5
double costPerLot = CommissionPerLot + FeePerLot;   // inputs, measured from history
double lossPerLot = MathAbs(profitAtStop) + MathMax(0.0, costPerLot);
```

After a fill:

```mql5
if(!PositionSelectByTicket(positionTicket))
   return;
double sl = PositionGetDouble(POSITION_SL);
double tp = PositionGetDouble(POSITION_TP);
if(sl == 0.0 || tp == 0.0)
{
   Print("Filled without the requested SL/TP. Closing.");
   trade.PositionClose(positionTicket);
}
```

Log `trade.ResultPrice()` and `trade.ResultVolume()` next to the requested price and volume.

### L1. Drop yesterday's keys

```mql5
void DeleteOldDailyKeys()
{
   string prefix = StringFormat("PXBTSTD_CRYPTO_%I64d_",
                                AccountInfoInteger(ACCOUNT_LOGIN));
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string today = StringFormat("%04d%02d%02d", dt.year, dt.mon, dt.day);
   for(int i = GlobalVariablesTotal() - 1; i >= 0; --i)
   {
      string name = GlobalVariableName(i);
      if(StringFind(name, prefix) != 0)
         continue;
      if(StringFind(name, today) >= 0)
         continue;
      GlobalVariableDel(name);
   }
}
```

Call once from `OnInit`, after the account is connected, so `TimeCurrent` is a real server day.

### L2, L3, L4

Add `SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL)` into `minDistance` if you want the defensive form. Reject `DeviationPoints < 0` and `MagicNumber == 0` next to the other init checks. One `Print` per bar for the filter that returned.

## Sources

Pages read on 3 November 2026.

MQL5 and MetaTrader:

- [Program properties](https://www.mql5.com/en/docs/basis/preprosessor/compilation)
- [Program running](https://www.mql5.com/en/docs/runtime/running) (one thread per Expert Advisor; at most a 5-second start delay)
- [Testing trading strategies](https://www.mql5.com/en/docs/runtime/testing) (tick models, spread, per-agent global variables)
- [GlobalVariableSetOnCondition](https://www.mql5.com/en/docs/globals/globalvariablesetoncondition)
- [GlobalVariableTemp](https://www.mql5.com/en/docs/globals/globalvariabletemp)
- [Terminal global variables](https://www.mql5.com/en/book/common/globals) (63-character names, `gvariables.dat`, tester lifetime)
- [OrderCalcProfit](https://www.mql5.com/en/docs/trading/ordercalcprofit) and the [formula chapter](https://www.mql5.com/en/book/automation/experts/experts_ordercalcprofit)
- [Symbol properties](https://www.mql5.com/en/docs/constants/environment_state/marketinfoconstants) (`SYMBOL_TRADE_STOPS_LEVEL`, `SYMBOL_TRADE_FREEZE_LEVEL`)
- [Checks a trading robot must pass](https://www.mql5.com/en/articles/2555) (stop distance versus freeze-on-modify)
- [iMA](https://www.mql5.com/en/docs/indicators/ima)
- [Position accounting](https://www.metatrader5.com/en/terminal/help/trading/general_concept)
- [MetaEditor command line](https://www.metatrader5.com/en/metaeditor/help/beginning/integration_ide)
- [Virtual Hosting rules](https://www.mql5.com/en/vps/rules)
- [Virtual Hosting prices](https://www.mql5.com/en/vps/forex-plans)
- Community reports, not vendor docs: [`#property strict`](https://www.mql5.com/en/forum/425625), [calendar error 4014 in the tester](https://www.mql5.com/en/forum/312462), [MetaEditor exit code](https://www.mql5.com/en/forum/519259)

PrimeXBT:

- [Crypto CFDs on MT5 are spread-only (5 September 2025)](https://primexbt.com/company-blog/crypto-cfds-on-pxtrader-and-mt5-are-now-spread-only/)
- [Crypto CFDs listed on MT5 (6 May 2025)](https://primexbt.com/company-blog/crypto-cfds-now-available-on-mt5-with-expanded-instrument-selection/)
- [Swap timestamps (2024)](https://primexbt.com/company-blog/important-information-regarding-swaps-on-primexbt-and-mt5/)
- [Trading conditions (6 August 2026)](https://primexbt.help/en/articles/16240701-trading-conditions-explained)
- [FAQ](https://primexbt.help/en/articles/8461245-frequently-asked-questions-f-a-q-platform-wide)
